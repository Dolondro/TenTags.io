
local CONFIG_CHECK_INTERVAL = 5

local config = {}
config.__index = config
config.http = require 'lib.http'
config.cjson = require 'cjson'

local redisRead = require 'api.redisread'
local redisWrite = require 'api.rediswrite'
local cache = require 'api.cache'
local TAG_BOUNDARY = 0.15
local to_json = (require 'lapis.util').to_json
local from_json = (require 'lapis.util').from_json

local SPECIAL_TAGS = {
	nsfw = 'nsfw'
}

function config:New(util)
  local c = setmetatable({},self)
  c.util = util

  return c
end

function config.Run(_,self)
  local ok, err = ngx.timer.at(CONFIG_CHECK_INTERVAL, self.Run, self)
  if not ok then
    if not err:find('process exiting') then
      ngx.log(ngx.ERR, 'WARNING: unable to reschedule postupdater: '..err)
    end
  end

  -- no need to lock since we should be grabbing a different one each time anyway

	self:ProcessJob('UpdateFilterPosts', 'UpdateFilterPosts')

end



function config:ConvertToUnique(jsonData)
  -- this also removes duplicates, using the newest only
  -- as they are already sorted old -> new by redis
  local commentVotes = {}
  local converted
  for _,v in pairs(jsonData) do

    converted = from_json(v)
    converted.json = v
		if not converted.id then
			ngx.log(ngx.ERR, 'jsonData contains no id: ',v)
		end
    commentVotes[converted.id] = converted
  end
  return commentVotes
end


function config:ProcessJob(jobName, handler)

  local lockName = 'L:'..jobName
  local ok,err = redisRead:GetOldestJobs(jobName, 1000)
  if err then
    ngx.log(ngx.ERR, 'unable to get list of comment votes:' ,err)
    return
  end

  local jobs = self:ConvertToUnique(ok)

  for jobID,job in pairs(jobs) do
    ok, err = redisWrite:GetLock(lockName..jobID,10)
    if err then
      ngx.log(ngx.ERR, 'unable to lock commentvote: ',err)
    elseif ok ~= ngx.null then
      -- the bit that does stuff
      ok, err = self[handler](self,job)
      if ok then
        redisWrite:RemoveJob(jobName,job.json)
        -- purge the comment from the cache
        -- dont remove lock, just to limit updates a bit
      else
        ngx.log(ngx.ERR, 'unable to process commentvote: ', err)
        redisWrite:RemLock(lockName..jobID)
      end
    end
  end

end



--DRY, needs combining with api:AverageTagScore
local function AverageTagScore(filterrequiredTagNames,postTags)

	local score = 0
	local count = 0

  for _,filterTagName in pairs(filterrequiredTagNames) do
    for _,postTag in pairs(postTags) do
      if filterTagName == postTag.name then
				if (not postTag.name:find('^meta:')) and
					(not postTag.name:find('^source:')) and
					postTag.score > TAG_BOUNDARY then
	        	score = score + postTag.score
						count = count + 1
				end
      end
    end
  end

	if count == 0 then
		return 0
	end

	return score / count
end

function config:GetUpdatedFilterPosts(filter, requiredTagNames, bannedTagNames)
	print(to_json(filter))
  local newPostsKey = filter.id..':tempPosts'
	local oldPostsKey = 'filterposts:'..filter.id

  local ok, err = redisWrite:CreateTempFilterPosts(newPostsKey, requiredTagNames, bannedTagNames)
  if not ok then
    return ok, err
  end

  local oldPostIDs = redisWrite:GetSetDiff(oldPostsKey, newPostsKey)
  --print('old posts:'..to_json(oldPostIDs))
  local newPostIDs = redisWrite:GetSetDiff(newPostsKey, oldPostsKey)
  --print('new posts:'..to_json(newPostIDs))

  local newPosts = cache:GetPosts(newPostIDs)
  redisWrite:DeleteKey(newPostsKey)
  return newPosts, oldPostIDs

end


function config:GetRelatedFilters(filter)

	-- for each tag, get filters that also have that tag
	local tagNames = {}
	for _,tagName in pairs(filter.requiredTagNames) do
		table.insert(tagNames, {name = tagName})
	end

	local filterIDs = cache:GetFilterIDsByTags(tagNames)
	local filters = {}
	for _,v in pairs(filterIDs) do
		for filterID,_ in pairs(v) do
			if filterID ~= filter.id then
				table.insert(filters, cache:GetFilterByID(filterID))
			end
		end
	end

--	print('this: ',to_json(filters))
	for _,relatedFilter in pairs(filters) do
		local count = 0
		for _,relatedTagName in pairs(relatedFilter.requiredTagNames) do
			for _, filterTagName in pairs(filterIDs) do
				if relatedTagName == filterTagName then
					count = count + 1
				end
			end
		end
		relatedFilter.relatedTagsCount = count
	end

	table.sort(filters, function(a,b) return a.relatedTagsCount > b.relatedTagsCount end)

	local finalFilters = {}
	for i = 1, math.min(5, #filters) do
		table.insert(finalFilters, filters[i].id)
	end

	return finalFilters

end


function config:UpdateFilterPosts(data)

	local filter = redisRead:GetFilterByID(data.id)
	if not filter then
		ngx.log(ngx.ERR, 'couldnt load filter id: ', data.id)
		return true
	end


	local ok, err
	local requiredTagNames = filter.requiredTagNames

	local bannedTagNames = filter.bannedTagNames

	local newPosts, oldPostIDs = self:GetUpdatedFilterPosts(filter, requiredTagNames, bannedTagNames)

	--get new post scores
	for _, newPost in pairs(newPosts) do
		newPost.score = AverageTagScore(requiredTagNames, newPost.tags)
	end

	--update all the affected posts so they remove/add themselves to filters
	for _,post in pairs(newPosts) do
		ok, err = redisWrite:QueueJob('UpdatePostFilters', {id = post.id})
		if not ok then
			return ok, err
		end
	end
	for _,postID in pairs(oldPostIDs) do
		ok, err = redisWrite:QueueJob('UpdatePostFilters', {id = postID})
		if not ok then
			return ok, err
		end
	end

	ok , err = redisWrite:AddPostsToFilter(filter, newPosts)
	if not ok then
		print('error adding posts to filter: ',err)
		return ok, err
	end

	ok, err = redisWrite:RemovePostsFromFilter(filter.id, oldPostIDs)
	if not ok then
		print(ok, err)
		return ok, err
	end

	local relatedFilters = self:GetRelatedFilters(filter)
	ok, err = redisWrite:UpdateRelatedFilters(filter, relatedFilters)



end




return config
