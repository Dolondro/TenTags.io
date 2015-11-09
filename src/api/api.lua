--[[
  access control
  rate limitting
  business logic
]]

local cache = require 'api.cache'
local api = {}
local uuid = require 'lib.uuid'
local worker = require 'api.worker'
local tinsert = table.insert
local trim = (require 'lapis.util').trim
local scrypt = require 'lib.scrypt'
local salt = 'poopants'
--local to_json = (require 'lapis.util').to_json
local magick = require 'magick'
local http = require 'lib.http'
local rateDict = ngx.shared.ratelimit
--arbitrary, needs adressing later
local TAG_BOUNDARY = 0.15
local TAG_START_DOWNVOTES = 0
local TAG_START_UPVOTES = 5
local COMMENT_START_DOWNVOTES = 0
local COMMENT_START_UPVOTES = 5
local COMMENT_LENGTH_LIMIT = 2000
local POST_TITLE_LENGTH = 300
--local permission = require 'userpermission'

local ENABLE_RATELIMIT = true

function api:RateLimit(key, limit,duration)
	if not ENABLE_RATELIMIT then
		return true
	end

	local ok, err = rateDict:get(key)

	if not ok then
		rateDict:set(key, 0, duration)
	end

	rateDict:incr(key,1)

	if not ok then
		return true
	end

	if ok <= limit then
		return ok
	else
		return nil, 429
	end

end

function api:UpdateUser(userID, userToUpdate)

	local ok, err = self:RateLimit('UpdateUser:'..userID, 3, 30)
	if not ok then
		return ok, err
	end

	if userID ~= userToUpdate.id then
		local user = cache:GetUserInfo(userID)
		if user.role ~= 'Admin' then
			return nil, 'you must be admin to edit a users details'
		end
	end

	local userInfo = {
		id = userToUpdate.id,
		enablePM = userToUpdate.enablePM and 1 or 0,
		hideSeenPosts = userToUpdate.hideSeenPosts and 1 or 0
	}

	return worker:UpdateUser(userInfo)
end

function api:SanitiseHTML(str)
	local html = {
		["<"] = "&lt;",
		[">"] = "&gt;",
		["&"] = "&amp;",
	}
	return string.gsub(tostring(str), "[<>&]", function(char)
		return html[char] or char
	end)
end

function api:GetUserFilters(userID)
	-- can only get your own filters
  if not userID then
    userID = 'default'
  end
  local filterIDs = cache:GetUserFilterIDs(userID)

  return cache:GetFilterInfo(filterIDs)
end


function api:GetFilterInfo(filterIDs)
	return cache:GetFilterInfo(filterIDs)
end

function api:GetPostComments(userID, postID,sortBy)
	local comments = cache:GetSortedComments(userID, postID,sortBy)


	return comments
end

function api:GetComment(postID, commentID)
  return cache:GetComment(postID, commentID)
end

function api:GetThread(threadID)
  return cache:GetThread(threadID)
end

function api:UserHasAlerts(userID)
	--can only get your own alerts
  local alerts = cache:GetUserAlerts(userID)
  return #alerts > 0
end

function api:UserIsMod(userID, filterID)

end

function api:UserIsAdmin(user)


end

function api:UserCanEditFilter(userID, filterID)
	local user = cache:GetUserInfo(userID)

	if not user then
		return nil, 'userID not found'
	end

	if user.role == 'Admin' then
		return true
	end

	local filter = cache:GetFilterByID(filterID)

	if filter.ownerID == userID then
		return true
	end

	for _,mod in pairs(filter.mods) do
		if mod.id == userID then
			return true
		end
	end

	return false, 'you must be admin or mod to edit filters'
end


function api:FilterBanUser(userID, filterID, banInfo)

	local ok, err = self:UserCanEditFilter(userID, filterID)
	if not ok then
		return ok, err
	end

	banInfo.bannedAt = ngx.time()
	return worker:FilterBanUser(filterID, banInfo)
end

function api:FilterUnbanDomain(userID, filterID, domainName)
	local ok, err = self:UserCanEditFilter(userID, filterID)
	if not ok then
		return ok, err
	end

	domainName = self:GetDomain(domainName) or domainName
	return worker:FilterUnbanDomain(filterID, domainName)
end

function api:GetUserAlerts(userID)
	-- can only get their own
  local alerts = cache:GetUserAlerts(userID)
  -- TODO: need to also update the users lastcheckedAt
  -- both in redis and the cache (when it caches)

  return alerts
end

function api:UpdateLastUserAlertCheck(userID)
	local ok, err = self:RateLimit('UpdateUserAlertCheck:'..userID, 5, 10)
	if not ok then
		return ok, err
	end
	-- can only edit their own
  return worker:UpdateLastUserAlertCheck(userID)
end

function api:VerifyMessageSender(userID, messageInfo)
	messageInfo.createdBy = messageInfo.createdBy or userID
	if userID ~= messageInfo.createdBy then
		--check if they can send a message as another user
		local user = cache:GetInfo(userID)
		if not user then
			return nil, 'could not find user'
		end
		if user.role and user.role ~= 'Admin' then
			messageInfo.createdBy = userID
		end
	end
end

function api:SanitiseUserInput(msg, length)
	if type(msg) ~= 'string' then
		ngx.log(ngx.ERR, 'string expected, got: ',type(msg))
		return ''
	end
	if msg == '' then
		ngx.log(ngx.ERR, 'string is blank')
		return ''
	end

	msg = self:SanitiseHTML(msg)
	if not length then
		return msg
	end

	return msg:sub(1, length)

end

function api:ConvertUserMessageToMessage(userID, userMessage)
	if not userMessage.threadID then
		return nil, 'no thread id'
	end

	if not userMessage.createdBy then
		userMessage.createdBy = userID
	end

	local newInfo = {
		threadID = self:SanitiseUserInput(userMessage.threadID, 200),
		body = self:SanitiseUserInput(userMessage.body, 2000),
		id = uuid.generate_random(),
		createdAt = ngx.time(),
		createdBy = self:SanitiseUserInput(userMessage.createdBy)
	}

	local ok, err = self:VerifyMessageSender(userID, newInfo)
	if not ok then
		return ok, err
	end

	return newInfo
end

function api:CreateMessageReply(userID, userMessage)
	local newMessage, ok, err

	newMessage, err = self:ConvertUserMessageToMessage(userID, userMessage)

	if not newMessage then
		return newMessage, err
	end

  ok, err = worker:CreateMessage(userMessage)
	if not ok then
		return ok, err
	end

  local thread = cache:GetThread(newMessage.threadID)
  for _,viewerID in pairs(thread.viewers) do
    if viewerID ~= newMessage.createdBy then
      worker:AddUserAlert(viewerID, 'thread:'..thread.id..':'..newMessage.id)
    end
  end

end



function api:CreateThread(userID, messageInfo)

	local ok, err = self:VerifyMessageSender(userID, messageInfo)
	if not ok then
		return err
	end

	ok, err = self:RateLimit('CreateThread:'..userID, 2, 30)
	if not ok then
		return ok, err
	end

  local recipientID = cache:GetUserID(messageInfo.recipient)
	if not recipientID then
		return nil, 'couldnt find recipient user'
	end

  local thread = {
    id = uuid.generate_random(),
    createdBy = messageInfo.createdBy,
    createdAt = ngx.time(),
    title = self:SanitiseHTML(messageInfo.title),
    viewers = {messageInfo.createdBy,recipientID},
    lastUpdated = ngx.time()
  }

  local msg = {
    id = uuid.generate_random(),
    createdBy = messageInfo.createdBy,
    body = self:SanitiseHTML(messageInfo.body),
    createdAt = ngx.time(),
    threadID = thread.id
  }

  worker:CreateThread(thread)
  worker:CreateMessage(msg)
  worker:AddUserAlert(recipientID, 'thread:'..thread.id..':'..msg.id)

end

function api:GetUserID(username)
	return cache:GetUserID(username)
end

function api:GetThreads(userID)
  return cache:GetThreads(userID)
end

function api:SubscribeComment(userID, postID, commentID)

	local ok, err = self:RateLimit('SubscribeComment:'..userID, 3, 10)
	if not ok then
		return ok, err
	end

  local comment = cache:GetComment(postID, commentID)
  -- check they dont exist
  for _, v in pairs(comment.viewers) do
    if v == userID then
      return
    end
  end
  tinsert(comment.viewers, userID)
  worker:ent(comment)
end


function api:GetUserComments(userID, targetUserID)
	-- check if they allow it
	local targetUser = cache:GetUserInfo(targetUserID)
	if not targetUser then
		return nil, 'could not find user by ID '..targetUserID
	end

	if targetUser.hideComments then
		local user = cache:GetUserInfo(userID)
		if not user.role == 'Admin' then
			return nil, 'user has disabled comment viewing'
		end
	end

  local comments = cache:GetUserComments(targetUserID)
  return comments
end

function api:UserHasVotedComment(userID, commentID)
	-- can only see own
	local userCommentVotes = cache:GetUserCommentVotes(userID)
	return userCommentVotes[commentID]
end

function api:UserHasVotedPost(userID, postID)
	-- can only see own
	local userPostVotes = cache:GetUserPostVotes(userID)
	return userPostVotes[postID]

end

function api:UserHasVotedTag(userID, postID, tagID)
	-- can only see own
	local userTagVotes = cache:GetUserTagVotes(userID)
	return userTagVotes[postID..':'..tagID]

end

function api:GetScore(up,down)
	--http://julesjacobs.github.io/2015/08/17/bayesian-scoring-of-ratings.html
	--http://www.evanmiller.org/bayesian-average-ratings.html
	if up == 0 then
      return -down
  end
  local n = up + down
  local z = 1.64485 --1.0 = 85%, 1.6 = 95%
  local phat = up / n
  return (phat+z*z/(2*n)-z*math.sqrt((phat*(1-phat)+z*z/(4*n))/n))/(1+z*z/n)

end

function api:VoteComment(userID, postID, commentID,direction)
	-- do we ever need permissions for this??

	-- check if the user has already voted
	-- if theyve voted down then remove down entry,
	-- check if they can vote more than once
	-- increment comment votes
	-- recalculate score
	-- add to user voted in cache
	-- add to user voted in redis
	-- for now dont allow unvoting

	--if self:UserHasVotedComment(userID, commentID) then
		--return if they cant multivote
	--end


	local comment = api:GetComment(postID, commentID)
	if direction == 'up' then
		comment.up = comment.up + 1
	elseif direction == 'down' then
		comment.down = comment.down + 1
	end

	comment.score = self:GetScore(comment.up,comment.down)

	local ok, err = worker:AddUserCommentVotes(userID, commentID)
	if not ok then
		return ok, err
	end

	return worker:UpdateComment(comment)

	-- also add to user voted comments?

end

function api:GetMatchingTags(userFilterIDs, postFilterIDs)
	-- find the filters that intersect
	-- find the tags of the filters
	local matchingTags = {}
	local matchedFilter
	for _,userFilterID in pairs(userFilterIDs) do
		for _, postFilterID in pairs(postFilterIDs) do
			if userFilterID == postFilterID then
				--print('found matching: ',userFilterID)
				matchedFilter = cache:GetFilterByID(userFilterID)
				for _,tagID in pairs(matchedFilter.requiredTags) do
					print('adding tag: ',tagID)
					-- prevent duplicates
					matchingTags[tagID] = tagID
				end
			end
		end
	end
	return matchingTags
end

function api:GetUnvotedTags(user,postID, tagIDs)
	if user.role == 'admin' then
		return tagIDs
	end

	local keyedVotedTags = cache:GetUserTagVotes(user.id)

	local unvotedTags = {}
	for _, v in pairs(tagIDs) do
		if not keyedVotedTags[postID..':'..v] then
			tinsert(unvotedTags, v)
		end
	end
	return unvotedTags

end

function api:UpdateFilterTags(userID, filter, requiredTags, bannedTags)

	local ok, err = self:UserCanEditFilter(userID)
	if not ok then
		return ok, err
	end

	-- get the actual tag from the tagID
	for k,v in pairs(requiredTags) do
		if v ~= '' then
	 		requiredTags[k] = self:CreateTag(userID, v).id
		end
	end
	for k,v in pairs(bannedTags) do
		if v ~= '' then
			bannedTags[k] = self:CreateTag(userID, v).id
		end
	end

	local newPosts, oldPostIDs = worker:GetUpdatedFilterPosts(filter, requiredTags, bannedTags)

  -- filter needs to have a score per post
  for _, newPost in pairs(newPosts) do
    local matchingTags = self:GetPostFilterTagIntersection(requiredTags, newPost.tags)
		local score = 0
		local count = 0
		for _,tag in pairs(matchingTags) do
			if not tag.name:find('^meta:') then
				score = score + tag.score
				count = count + 1
			end
		end
		newPost.score = score / count
  end

  worker:AddPostsToFilter(filter, newPosts)


  worker:RemovePostsFromFilter(filter.id, oldPostIDs)
  return worker:UpdateFilterTags(filter, requiredTags, bannedTags)


end

function api:UpdatePostFilters(post)
	--[[
		since addfilters and updatefilters are the same, we can just add
		all of the newfilters, even if they already exist
	]]

	local newFilters = self:CalculatePostFilters(post)
	local purgeFilterIDs = {}

	for _,filterID in pairs(post.filters) do
		if not newFilters[filterID] then
			purgeFilterIDs[filterID] = filterID
		end
	end

	worker:RemovePostFromFilters(post.id, purgeFilterIDs)
	worker:AddPostToFilters(post, newFilters)

	post.filters = newFilters
end

function api:VotePost(userID, postID, direction)

	local ok, err = self:RateLimit('VotePost:'..userID, 10, 60)
	if not ok then
		return ok, err
	end

	--[[
		when we vote down a post as a whole we are saying
		'this post is not good enough to be under these filters'
		or 'the tags this post has that match the filters i care about are
		not good'

	]]
	local post = cache:GetPost(postID)
	if not post then
		return nil, 'post not found'
	end
	--local user = cache:GetUserInfo(userID)
	--if self:UserHasVotedPost(userID, postID) then
	--	return nil, 'already voted'
	--end

	-- get tags matching the users filters' tags
	print('get matching tags')
	local matchingTags = self:GetMatchingTags(cache:GetUserFilterIDs(userID),post.filters)
	--print(to_json(matchingTags))

	-- filter out the tags they already voted on
	--matchingTags = self:GetUnvotedTags(user,postID, matchingTags)
	for _,tagID in pairs(matchingTags) do
		for _,tag in pairs(post.tags) do
			--print(tagID ,' ', tag.id)
			if tag.id == tagID then
				self:AddVoteToTag(tag, direction)
			end
		end
	end

	self:UpdatePostFilters(post)
	worker:UpdatePostTags(post)

	worker:AddUserTagVotes(userID,postID, matchingTags)
	worker:AddUserPostVotes(userID, postID)

	return true


end

function api:AddVoteToTag(tag,direction)
	if direction == 'up' then
		print('vote up')
		tag.up = tag.up + 1
	elseif direction == 'down' then
		print('vote down')
		tag.down = tag.down + 1
	end
	-- recalculate the tag score
	tag.score = self:GetScore(tag.up,tag.down)
	print(tag.score)
end

function api:ConvertUserCommentToComment(userID, comment)

	comment.createdBy = comment.createdBy or userID
	if comment.createdBy ~= userID then
		local user = cache:GetUserInfo(userID)
		if user.role ~= 'Admin' then
			return nil, 'you cannot create a comment on behalf of someone else'
		end
	end

	local newComment = {
		id = uuid.generate_random(),
		createdAt = ngx.time(),
		createdBy = self:SanitiseUserInput(comment.createdBy),
		up = COMMENT_START_UPVOTES,
		down = COMMENT_START_DOWNVOTES,
		score = self:GetScore(COMMENT_START_UPVOTES,COMMENT_START_DOWNVOTES),
		viewers = {comment.createdBy},
		text = self:SanitiseUserInput(comment.text, COMMENT_LENGTH_LIMIT),
		parentID = self:SanitiseUserInput(comment.parentID),
		postID = self:SanitiseUserInput(comment.postID)
	}

	return newComment
end

function api:EditComment(userID, userComment)
	local ok, err = self:RateLimit('EditComment:'..userID, 4, 120)
	if not ok then
		return ok, err
	end

	if not userComment or not userComment.id or not userComment.postID then
		return nil, 'invalid comment provided'
	end

	local comment = cache:GetComment(userComment.postID, userComment.id)
	if not comment then
		return nil, 'comment not found'
	end

	if comment.createdBy ~= userID then
		local user = cache:GetUserInfo(userID)
		if not user or user.role ~= 'Admin' then
			return nil, 'you cannot edit other users comments'
		end
	end

	comment.text = userComment.text
	comment.editedAt = ngx.time()

	ok, err = worker:CreateComment(comment)
	
	return ok, err

	-- dont change post comment count

end

function api:CreateComment(userID, userComment)
	-- check if they are who they say they are

	local ok, err = self:RateLimit('CreateComment:'..userID, 1, 30)
	if not ok then
		return ok, err
	end

	local newComment = api:ConvertUserCommentToComment(userID, userComment)


  local filters = {}
	local parentPost = cache:GetPost(newComment.postID)
	if not parentPost then
		return nil, 'could not find parent post'
	end


  local postFilters = parentPost.filters
  local userFilters = self:GetUserFilters(newComment.createdBy)

	-- get shared filters between user and post
  for _,userFilter in pairs(userFilters) do
    for _,postFilterID in pairs(postFilters) do
      if userFilter.id == postFilterID then
        tinsert(filters, userFilter)
      end
    end
  end

  newComment.filters = filters

	-- TODO: check comment is also added to users list of comments
  local ok, err = worker:CreateComment(newComment)
	if not ok then
		return ok, err
	end

  -- need to add alert to all parent comment viewers
  if newComment.parentID == newComment.postID then
    -- TODO: whole other kettle of fish
  else
    local parentComment = self:GetComment(newComment.postID, newComment.parentID)
    for _,viewerID in pairs(parentComment.viewers) do
      worker:AddUserAlert(viewerID, 'postComment:'..newComment.postID..':'..newComment.id)
    end
  end

	local post = cache:GetPost(newComment.postID)

	worker:UpdatePostField(newComment.postID, 'commentCount',post.commentCount+1)

	return true

end

function api:GetPost(userID, postID)

	if not postID then
		return nil, 'no postID!'
	end

	local post = cache:GetPost(postID)
	if not post then
		return nil, 'post not found'
	end

	local userVotedTags = cache:GetUserTagVotes(userID)

	for _,tag in pairs(post.tags) do
		if userVotedTags[postID..':'..tag.id] then
			tag.userHasVoted = true
		end
	end


  return post
end

function api:GetDefaultFrontPage(range,filter)
  range = range or 0
  filter = filter or 'fresh'
  return cache:GetDefaultFrontPage(range,filter)
end


function api:SubscribeToFilter(userID,filterID)

  local filterIDs = cache:GetUserFilterIDs(userID)

  for _, v in pairs(filterIDs) do
    if v == filterID then
      -- they are already subbed
      return
    end
  end

  worker:SubscribeToFilter(userID,filterID)

end

function api:GetUserInfo(userID)
	-- can only get own for now
	if not userID or userID == '' then
		return nil
	end

	local userInfo  = cache:GetUserInfo(userID)

	return userInfo
end

function api:FilterUnbanUser(filterID, userID)
	local ok, err = self:UserCanEditFilter(userID, filterID)
	if not ok then
		return ok, err
	end

	return worker:FilterUnbanUser(filterID, userID)
end

function api:FilterBanDomain(filterID, banInfo)
	local ok, err = self:UserCanEditFilter(userID, filterID)
	if not ok then
		return ok, err
	end

	banInfo.bannedAt = ngx.time()
	banInfo.domainName = self:GetDomain(banInfo.domainName) or banInfo.domainName
	return worker:FilterBanDomain(filterID, banInfo)
end

function api:ValidateMaster(userCredentials)
  local masterInfo = cache:GetMasterUserByEmail(userCredentials.email)

  if not masterInfo then
    return
  end

  if masterInfo.active == 0 then
    return nil,true
  end

  local valid = scrypt.check(userCredentials.password,masterInfo.passwordHash)
  if valid then
    masterInfo.passwordHash = nil
    return masterInfo
  end

end

function api:CreateActivationKey(masterInfo)
  local key = ngx.md5(masterInfo.id..masterInfo.email..salt)
  return key:match('.+(........)$')
end

function api:ActivateAccount(email, key)
  email = email and email:lower() or ''
  if email == '' then
    return nil, 'email is blank!'
  end

  local userInfo = cache:GetMasterUserByEmail(email)
  if not userInfo then
    return nil, 'could not find account with this email'
  end

  local realKey = self:CreateActivationKey(userInfo)
  if key == realKey then
    --cache:UpdateUserInfo(userInfo)
    worker:ActivateAccount(userInfo.id)
    return true
  else
    return nil, 'activation key incorrect'
  end
end

function api:GetUserFrontPage(userID,filter,range)
	-- can only get own
  return cache:GetUserFrontPage(userID,filter,range)
end


function api:CreateSubUser(masterID, username)

  local subUser = {
    id = uuid.generate(),
    username = self:SanitiseHTML(username,20),
    filters = cache:GetUserFilterIDs('default'),
    parentID = self:SanitiseHTML(masterID,50),
    enablePM = 1
  }

  local master = cache:GetMasterUserInfo(masterID)
  tinsert(master.users,subUser.id)

  worker:CreateMasterUser(master)

  return worker:CreateSubUser(subUser)

	-- TODO check incr userCount by one

end

function api:GetMasterUsers(userID, masterID)
  local master = cache:GetMasterUserInfo(masterID)
  local users = {}
  local user = cache:GetUserInfo(userID)

	if user.role ~= 'Admin' then
		local found = nil
		for _,subUserID in pairs(master.users) do
			if userID == subUserID then
				found = true
				break
			end
		end
		if not found then
			return nil, 'must be admin to view other users'
		end
	end

	local subUser
  for _, subUserID in pairs(master.users) do
      subUser = cache:GetUserInfo(subUserID)
      if user then
        tinsert(users, subUser)
      end
  end
  return users
end

function api:ConvertUserMasterToMaster(master)


	if not master.username then
		return nil, 'no username given'
	end

	if not master.password then
		return nil, 'no password given'
	end

	if not master.email then
		return nil, 'no email given'
	end

	master.username = master.username:gsub(' ','')
	master.password = master.password:gsub(' ','')
	master.email = master.email:gsub(' ','')

	if #master.password > 200 then
		return nil, 'password must be shorter than 200 chars'
	end
	if #master.password < 8 then
		return nil, 'password must be longer than 8 chars'
	end

	local newMaster = {
		username = self:SanitiseUserInput(master.username, 20),
		password = master.password,
		email = self:SanitiseUserInput(master.email),
		passwordHash = scrypt.crypt(master.password),
		id = uuid.generate_random(),
		active = 0,
		userCount = 1,
		users = {}
	}




end

function api:CreateMasterUser(confirmURL, userInfo)

	local newMaster = api:ConvertUserMasterToMaster(userInfo)


  local firstUser = {
    id = uuid.generate_random(),
    username = newMaster.username,
    filters = cache:GetUserFilterIDs('default'),
    parentID = newMaster.id
  }

  tinsert(newMaster.users,firstUser.id)
  newMaster.currentUserID = firstUser.id

  local activateKey = self:CreateActivationKey(newMaster)
  local url = confirmURL..'?email='..userInfo.email..'&activateKey='..activateKey
  worker:SendActivationEmail(url, userInfo.email)
  worker:CreateMasterUser(newMaster)
  worker:CreateSubUser(firstUser)
  return true

end

function api:UnsubscribeFromFilter(userID, subscriberID,filterID)
	if userID ~= subscriberID then
		local user = cache:GetUserInfo(userID)
		if user.role ~= 'Admin' then
			return nil, 'you must be admin to change another users subscriptions'
		end
	end


  local filterIDs = cache:GetUserFilterIDs(userID)
  local found = nil
  for _,v in pairs(filterIDs) do
    if v == filterID then
      found = true
    end
  end
  if not found then
    -- no need to unsubscribe
    return
  end

  worker:UnsubscribeFromFilter(subscriberID,filterID)


end

function api:CreateTag(userID, tagName)


  if tagName:gsub(' ','') == '' then
    return nil
  end

	tagName = self:SanitiseUserInput(tagName, 100)

  local tag = cache:GetTag(tagName)
  if tag then
    return tag
  end

  local tagInfo = {
    id = uuid.generate_random(),
    createdAt = ngx.time(),
    createdBy = userID,
    name = tagName
  }

  worker:CreateTag(tagInfo)
  return tagInfo
end



function api:GetDomain(url)
  return url:match('^%w+://([^/]+)')
end

function api:VoteTag(userID, postID, tagID, direction)

	local ok, err = self:RateLimit('VoteTag:'..userID, 5, 30)
	if not ok then
		return ok, err
	end

	if not direction then
		return nil, 'no direction'
	end

	-- check post for existing vote
	-- check tag for existing vote

	--if self:UserHasVotedPost(userID, postID) then
		--return nil, 'already voted'
	--end

	local post = cache:GetPost(postID)

	--if self:UserHasVotedTag(userID, postID, tagID) then
	--	return nil, 'already voted on tag'
	--end
	for _, tag in pairs(post.tags) do
		if tag.id == tagID then
			self:AddVoteToTag(tag, direction)
		end
	end


	local ok, err = worker:AddUserTagVotes(userID, postID, {tagID})
	if not ok then
		return ok, err
	end

	self:UpdatePostFilters(post)
	local ok, err = worker:UpdatePostTags(post)

end


function api:CreatePostTags(postInfo)
	for k,v in pairs(postInfo.tags) do

		v = trim(v:lower())
		postInfo.tags[k] = self:CreateTag(postInfo.createdBy, v)

		if postInfo.tags[k] then
			postInfo.tags[k].up = TAG_START_UPVOTES
			postInfo.tags[k].down = TAG_START_DOWNVOTES
			postInfo.tags[k].score = self:GetScore(TAG_START_UPVOTES,TAG_START_DOWNVOTES)
			postInfo.tags[k].active = true
		end
	end
end

function api:GetValidFilters(filterID, post)

	local filter = cache:GetFilterByID(filterID)
	if not filter then
		ngx.log(ngx.ERR,'filter not found: ',filterID)
		return nil
	end

	--rather than just checking they exist, also need to get
	-- all intersecting tags, and calculate an average score

	-- check all desired tags are present on the post
	local matchingTags = self:GetPostFilterTagIntersection(filter.requiredTags, post.tags)
	if not matchingTags or #matchingTags == 0 then
		--print('tags dont match')
		return nil
	end

	local score = 0
	local count = 0
	for _,tag in pairs(matchingTags) do
		if not tag.name:find('^meta:') then
			--print(tag.name.. ' '..tag.up.. ' '..tag.down)
			score = score + tag.score
			count = count + 1
		end
	end
	filter.score = score / count
	--print(filter.score)


	if (filter.bannedUsers[post.createdBy]) then
		ngx.log(ngx.ERR, 'ignoring filter: ',filter.id,' as user: ',post.createdBy, ' is banned')
		return nil
	elseif filter.bannedDomains[post.domain] then
		ngx.log(ngx.ERR, 'ignoring filter: ',filter.id,' as domain ',post.domain, ' is banned ' )
		return nil
	end
	return filter
end

function api:CalculatePostFilters(post)
	-- get all the filters that care about this posts' tags

	-- only include tags above threshold
	local validTags = {}
	for _, tag in pairs(post.tags) do
		if tag.score > TAG_BOUNDARY then
			print('valid tag: ',tag.id,tag.name)
			tinsert(validTags, tag)
		end
	end

	local filterIDs = cache:GetFilterIDsByTags(validTags)
  local chosenFilterIDs = {}

  -- add all the filters that want these tags
  for _,v in pairs(filterIDs) do
    for filterID,filterType in pairs(v) do
      if filterType == 'required' then
				--print('wants this tag: ',filterID)
        chosenFilterIDs[filterID] = filterID
      end
    end
  end

  -- remove all the filters that dont, or have bans
  for _,v in pairs(filterIDs) do
    for filterID,filterType in pairs(v) do
			if filterType == 'banned' then
				--print('doesnt want this tag: ',filterID)
				chosenFilterIDs[filterID] = nil
			else
				chosenFilterIDs[filterID] = self:GetValidFilters(filterID, post)
			end
    end
  end

	-- we now have [filterID] = {filter}
	-- also filter contains the new score

  return chosenFilterIDs
end

function api:LoadImage(httpc, imageInfo)
	local res, err = httpc:request_uri(imageInfo.link)
	if not res then
		--print(' cant laod image: ',imageInfo.link, ' err: ',err)
		return nil
	end
	--print(imageInfo.link, type(res.body), res.body)
	if res.body:len() > 0 then
		return res.body

	else
		print('empty body for '..imageInfo.link)
	end
	return nil
end

function api:GetIcon(newPost)
	--see if we can get the webpage
	--scan the webpage for image links
	--get the size of each link
	--create an icon from the largest image
	local httpc = http.new()
	local res, err = httpc:request_uri(newPost.link)
	if not res then
		print('failed: ', err)
		return
	end

	--print(res.body)
	local imageLinks = {}
	for imgTag in res.body:gmatch('<img.-src=[\'"](.-)[\'"].->') do
		if imgTag:find('^//') then
			imgTag = 'http:'..imgTag
		end
		tinsert(imageLinks, {link = imgTag})
	end

	for _, imageInfo in pairs(imageLinks) do
		local imageBlob = self:LoadImage(httpc, imageInfo)
		imageInfo.size = 0
		if imageBlob then
			local image = assert(magick.load_image_from_blob(imageBlob))

			--local icon = assert(magick.thumb(imageBlob, '100x100'))

			if image then
				imageInfo.image = image
				local w,h = image:get_width(), image:get_height()
				imageInfo.size = w*h
			end
		end
	end

	table.sort(imageLinks, function(a,b) return a.size > b.size end)

	local finalImage
	for k,v in pairs(imageLinks) do
		if v.image then
			finalImage = v
			break
		end
	end

	if not finalImage then
		return nil
	end

	finalImage.image:resize_and_crop(100,100)
	finalImage.image:set_format('png')
	if finalImage.link:find('.gif') then
		print('trying to coalesce')
		finalImage.image:coalesce()
	end
	--newPost.icon = finalImage:get_blob()
	newPost.icon = finalImage.image:get_blob()
	finalImage.image:write('static/icons/'..newPost.id..'.png')
	print('icon added, written to: ',newPost.id..'.png')

end

function api:ConvertUserPostToPost(userID, post)

	if not userID then
		return nil, 'no userID'
	end
	if not post then
		return nil, 'no post info'
	end

	post.createdBy = post.createdBy or userID
	if userID ~= post.createdBy then
		local user = cache:GetUserInfo(userID)
		if user.role ~= 'Admin' then
			post.createdBy = userID
		end
	end

	local newID = uuid.generate_random()

	local newPost = {
		id = newID,
		parentID = newID,
		createdBy = post.createdBy,
		commentCount = 0,
		title = self:SanitiseUserInput(post.title, POST_TITLE_LENGTH),
		link = post.link,
		text = self:SanitiseUserInput(post.text, 2000),
		createdAt = ngx.time()
	}

	newPost.tags = {}

	for _,v in pairs(post.tags) do
		tinsert(newPost.tags, self:SanitiseUserInput(v, 100))
	end


	return newPost

end

function api:GeneratePostTags(post)
	if not post.link or trim(post.link) == '' then
    tinsert(post.tags,'meta:type:self')
  end

  tinsert(post.tags,'meta:user:'..post.createdBy)
end

function api:CreatePost(userID, postInfo)

	local ok, err = self:RateLimit('CreatePost:'..userID, 1, 300)
	if not ok then
		return ok, err
	end

	-- TODO: move most of this to worker
	local newPost, ok, err

	newPost, err = self:ConvertUserPostToPost(userID, postInfo)
	if not newPost then
		return newPost, err
	end

	self:GeneratePostTags(newPost)

  if newPost.link then
		self:GetIcon(newPost)
    local domain  = self:GetDomain(newPost.link)
    if not domain then
      ngx.log(ngx.ERR, 'invalid url: ',newPost.link)
      return nil, 'invalid url'
    end
    newPost.domain = domain
    tinsert(newPost.tags,'meta:type:link')
    tinsert(newPost.tags,'meta:link:'..domain)
  end

	self:CreatePostTags(newPost)

	local postFilters = self:CalculatePostFilters(newPost)

	newPost.filters = {}
	for k,_ in pairs(postFilters) do
		tinsert(newPost.filters,k)
	end

  ok, err = worker:AddPostToFilters(newPost, postFilters)
	if not ok then
		return ok, err
	end

  ok, err = worker:CreatePost(newPost)
	if not ok then
		return ok, err
	end

  return true
end

function api:GetPostFilterTagIntersection(filterTags,postTags)

	local matchingTags = {}
  for _,filterTagID in pairs(filterTags) do
    for _,postTag in pairs(postTags) do
      if filterTagID == postTag.id then
        tinsert(matchingTags,postTag)
      end
    end
  end
	if #matchingTags == 0 then
		return nil
	end

  return matchingTags
end


function api:GetFilterPosts(filter)
  return cache:GetFilterPosts(filter)
end

function api:GetFilterByName(filterName)
  return cache:GetFilterByName(filterName)
end

function api:GetFiltersBySubs(offset,count)
  offset = offset or 0
  count = count or 10
  local filters = cache:GetFiltersBySubs(offset,count)
  return filters
end

function api:DelMod(userID, filterID, modID)

	local filter = cache:GetFilterByID(filterID)
	if not filter.ownerID == userID then
		local user = cache:GetUser(userID)
		if not user.role ~= 'Admin' then
			return nil, 'you must be admin or filter owner to remove mods'
		end
	end

	local found
	for _,mod in pairs(filter.mods) do
		if mod.id == userID then
			found = true
			break
		end
	end
	if not found then
		return nil, 'user is not a mod of this filter'
	end

	return worker:DelMod(filterID, modID)

end

function api:AddMod(userID, filterID, newModName)
	local filter = cache:GetFilterByID(filterID)

	if userID ~= filter.ownerID then
		local user = cache:GetUserInfo(userID)
		if user.role ~= 'Admin' then
			return nil, 'you must be admin or filter owner to add mods'
		end
	end


	local newModID = cache:GetUserID(newModName)
	if not newModID then
		return nil, 'could not find user with that name'
	end

	-- check they arent there already
	-- check they can be made mod of this sub

	local modInfo = {
		id = newModID,
		createdAt = ngx.time(),
		createdBy = userID,
		up = 10,
		down = 0,
	}
	return worker:AddMod(filterID, modInfo)

end

function api:ConvertUserFilterToFilter(userID, userFilter)
	userFilter.createdBy = userFilter.createdBy or userID
	if userID ~= userFilter.createdBy then
		local user = cache:GetUserInfo(userID)
		if user.role ~= 'Admin' then
			userFilter.createdBy = userID
		end
	end

	local newFilter = {
		id = uuid.generate_random(),
		name = self:SanitiseUserInput(userFilter.name, 30),
		description = self:SanitiseUserInput(userFilter.name, 2000),
		title = self:SanitiseUserInput(userFilter.name, 200),
		subs = 1,
		mods = {},
		requiredTags = {},
		bannedTags = {},
		ownerID = self:SanitiseUserInput(userFilter.ownerID,50),
		createdBy = self:SanitiseUserInput(userFilter.createdBy, 50),
		createdAt = ngx.time()
	}

	for _,v in pairs(userFilter.requiredTags) do
		tinsert(newFilter.requiredTags, self:SanitiseUserInput(v, 100))
	end

	for _,v in pairs(userFilter.requiredTags) do
		tinsert(newFilter.requiredTags, self:SanitiseUserInput(v, 100))
	end

	return newFilter
end

function api:CreateFilter(userID, filterInfo)

	local ok, err = self:RateLimit('CreateFilter:'..userID, 1, 600)
	if not ok then
		return ok, err
	end

	local newFilter, err

	newFilter, err = self:ConvertUserFilterToFilter(userID, filterInfo)
	if not newFilter then
		return newFilter, err
	end


  local tags = {}

  for k,tagName in pairs(newFilter.requiredTags) do
    local tag = self:CreateTag(newFilter.createdBy,tagName)
    if tag then
      tag.filterID = newFilter.id
      tag.filterType = 'required'
      tag.createdBy = newFilter.createdBy
      tag.createdAt = newFilter.createdAt
      tinsert(tags,tag)
      newFilter.requiredTags[k] = tag
    else
      newFilter.requiredTags[k] = nil
    end
  end

  for k,tagName in pairs(newFilter.bannedTags) do
    local tag = self:CreateTag(tagName, newFilter.createdBy)
    if tag then
      tag.filterID = newFilter.id
      tag.filterType = 'banned'
      tag.createdBy = newFilter.createdBy
      tag.createdAt = newFilter.createdAt
      tinsert(tags,tag)
      newFilter.bannedTags[k] = tag
    else
      --if its blank
      newFilter.bannedTags[k] = nil
    end
  end
  newFilter.tags = tags

  worker:CreateFilter(newFilter)


  return true
end


function api.GetAllTags()
  return cache:GetAllTags()
end


return api
