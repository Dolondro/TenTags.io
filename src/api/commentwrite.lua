

local redis = require "resty.redis"
local to_json = (require 'lapis.util').to_json
local from_json = (require 'lapis.util').from_json

local commentwrite = {}

local function GetRedisConnection()
  local red = redis:new()
  red:set_timeout(1000)
  local ok, err = red:connect("127.0.0.1", 6379)
  if not ok then
      ngx.say("failed to connect: ", err)
      return
  end
  red:select(1)
  return red
end

local function SetKeepalive(red)
  local ok, err = red:set_keepalive(10000, 100)
  if not ok then
      ngx.say("failed to set keepalive: ", err)
      return
  end
end

function commentwrite:ConvertListToTable(list)
  local info = {}
  for i = 1,#list, 2 do
    info[list[i]] = list[i+1]
  end
  return info
end

function commentwrite:UpdateCommentField(postID,commentID,field,newValue)
  print(postID, commentID)
  --get the comment, update, rediswrite
  local red = GetRedisConnection()
  local ok, err = red:hget('postComment:'..postID,commentID)
  if err then
    ngx.log(ngx.ERR, 'error getting comment: ',err)
    return ok, err
  end

  local comment  = from_json(ok)
  comment[field] = newValue
  local serialComment = to_json(comment)

  ok, err = red:hmset('postComment:'..comment.postID,comment.id,serialComment)
  SetKeepalive(red)
  if not ok then
    ngx.log(ngx.ERR, 'unable to write comment info: ',err)
    return false
  end
  return true
end

function commentwrite:CreateComment(commentInfo)

  local red = GetRedisConnection()
  local serialComment = to_json(commentInfo)
  print('creating comment: ',commentInfo.postID,commentInfo.id)
  local ok, err = red:hmset('postComment:'..commentInfo.postID,commentInfo.id,serialComment)
  SetKeepalive(red)
  if not ok then
    ngx.log(ngx.ERR, 'unable to write comment info: ',err)
    return false
  end
  return true
end


return commentwrite
