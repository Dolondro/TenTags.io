
local uuid = require 'lib.uuid'
local cache = require 'api.cache'

local base = require 'api.base'
local api = setmetatable({}, base)

local COMMENT_START_DOWNVOTES = 0
local COMMENT_START_UPVOTES = 1
local COMMENT_LENGTH_LIMIT = 2000
local userlib = require 'lib.userlib'
local userAPI = require 'api.users'

local app_helpers = require("lapis.application")
local assert_error = app_helpers.assert_error

function api:VoteComment(userID, postID, commentID,direction)

	if self:UserHasVotedComment(userID, commentID) then
		return nil, 'cannot vote more than once!'
	end

	local commentVote = {
		userID = userID,
		postID = postID,
		commentID = commentID,
		direction = direction,
		id = userID..':'..commentID
	}

	return assert_error(self.redisWrite:QueueJob('commentvote', commentVote))

end

function api:ConvertUserCommentToComment(userID, comment)


	local user = cache:GetUser(userID)

	if user.role == 'Admin' and user.fakeNames then
		local account = cache:GetAccount(user.parentID)
    local newUserName = userlib:GetRandom()
    user = userAPI:CreateSubUser(account.id, newUserName) or cache:GetUserID(newUserName)
    if user then
      comment.createdBy = user.id
    end
	else
		comment.createdBy = userID
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
		postID = self:SanitiseUserInput(comment.postID),
		viewID = user.currentView
	}

	return newComment
end

function api:SubscribeComment(userID, postID, commentID)

	local commentSub = {
		userID = userID,
		postID = postID,
		commentID = commentID,
		action = 'sub',
		id = userID..':'..commentID
	}

	return assert_error(self.redisWrite:QueueJob('commentsub', commentSub))

end


function api:EditComment(userID, userComment)
	-- not moving this to backend for now
	-- fairly low cost and users want immediate updates

	if not userComment or not userComment.id or not userComment.postID then
		return nil, 'invalid comment provided'
	end

	local comment = cache:GetComment(userComment.postID, userComment.id)

	if comment.createdBy ~= userID then
		local user = cache:GetUser(userID)
		if not user or user.role ~= 'Admin' then
			return nil, 'you cannot edit other users comments'
		end
	end

	comment.text = self:SanitiseUserInput(userComment.text,2000)
	comment.editedAt = ngx.time()

	local postComments = cache:GetPostComments(comment.postID)
	postComments[comment.id] = comment
	cache:WritePostComments(comment.postID, postComments)
	self:QueueUpdate('comment:edit', comment)
	--assert_error(self.commentWrite:CreateComment(comment))

	--return assert_error(self:InvalidateKey('comment', userComment.postID))
	print(to_json(comment))
	return comment
end

function api:CreateComment(userID, userComment)

	local newComment = api:ConvertUserCommentToComment(userID, userComment)

	self:InvalidateKey('comment', newComment.postID)

	-- add our new comment to the cache
	local postComments = cache:GetPostComments(newComment.postID)
	postComments[newComment.id] = newComment
	cache:WritePostComments(newComment.postID, postComments)
	self:QueueUpdate('comment:create', newComment)

	return newComment
end

function api:GetComment(postID, commentID)
	if not postID then
		return nil, 'no postID or commentURL'
	end

	if not commentID then
	 	local postIDCommentID = cache:ConvertShortURL(postID)
		postID, commentID = postIDCommentID:match('(%w+):(%w+)')
		if (not postID) or (not commentID) then
			return nil, 'error getting url'
		end
	end

  return assert_error(cache:GetComment(postID, commentID))
end


function api:UserHasVotedComment(userID, commentID)
	-- can only see own
	local userCommentVotes = cache:GetUserCommentVotes(userID)
	return userCommentVotes[commentID]
end



function api:GetUserComments(userID, targetUserID, sortBy, startAt, range)
	startAt = startAt or 0 -- 0 index for redis
	range = range or 20
	if not sortBy or not (sortBy == 'date' or sortBy == 'score') then
		sortBy = 'date'
	end

	-- check if they allow it
	local targetUser = assert_error(cache:GetUser(targetUserID))
	if not targetUser then
		return nil, 'could not find user by ID '..targetUserID
	end

	if targetUser.hideComments then
		local user = assert_error(cache:GetUser(userID))
		if not user.role == 'Admin' then
			return nil, 'user has disabled comment viewing'
		end
	end

  local comments = assert_error(cache:GetUserComments(targetUserID, sortBy,startAt, range))
	for _,v in pairs(comments) do
    v.username = assert_error(cache:GetUser(v.createdBy).username)
		v.post = assert_error(cache:GetPost(v.postID))
  end
  return comments
end

function api:DeleteComment(userID, postID, commentID)

	assert_error(self:RateLimit('DeleteComment:', userID, 6, 60))


	local post = assert_error(cache:GetPost(postID))
	if userID ~= post.createdBy then
		local user = assert_error(cache:GetUser(userID))
		if user.role ~= 'Admin' then
			return nil, 'cannot delete other users posts'
		end
	end

	local comment = assert_error(cache:GetComment(postID, commentID))
	if not comment then
		return nil, 'error loading comment'
	end
	comment.deleted = 'true'
	return assert_error(self.commentWrite:UpdateComment(comment))

end

function api:GetPostComments(userID, postID,sortBy)
	return cache:GetSortedComments(userID, postID,sortBy)
end
return api
