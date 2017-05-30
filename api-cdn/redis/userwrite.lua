
local addKey = require 'redisscripts.addkey'
local base = require 'redis.base'
local userwrite = setmetatable({}, base)

function userwrite:ConvertListToTable(list)
  local info = {}
  for i = 1,#list, 2 do
    info[list[i]] = list[i+1]
  end
  return info
end

function userwrite:LoadScript(script)
  local red = self:GetUserWriteConnection()
  local ok, err = red:script('load',script)
  if not ok then
    ngx.log(ngx.ERR, 'unable to add script to redis:',err)
    return nil
  else
    ngx.log(ngx.ERR, 'added script to redis: ',ok)
  end

  return ok
end

-- TODO:remove this
function userwrite:AddNewUser(time, accountID, email)
  local red = self:GetUserWriteConnection()

  local ok, err = red:zadd('newAccounts', time, accountID..':'..email)
  self:SetKeepalive(red)
  return ok, err
end

function userwrite:AddUserTagVotes(userID, postID, tagNames)
  local red = self:GetUserWriteConnection()
  for k,v in pairs(tagNames) do
    tagNames[k] = postID..':'..v
  end

  local ok, err = red:sadd('userTagVotes:'..userID, tagNames)
  self:SetKeepalive(red)
  if not ok then
    ngx.log(ngx.ERR, 'unable to add user tag vote: ',err)
  end
  return ok
end

function userwrite:AddUserCommentVotes(userID, commentID)
  local red = self:GetUserWriteConnection()

  local ok, err = red:sadd('userCommentVotes:'..userID, commentID)
  self:SetKeepalive(red)
  if not ok then
    ngx.log(ngx.ERR, 'unable to add user comment vote: ',err)
  end
  return ok
end

function userwrite:DeleteUser(userID, username)
--local account = cache:GetAccount(accountID)
  local red = self:GetUserWriteConnection()
  red:init_pipeline()
  red:hdel('userToID',username:lower())
  red:hset('user:'..userID, 'deleted', '1')
  local ok, err = red:commit_pipeline()
  self:SetKeepalive(red)
  return ok, err
end

function userwrite:AddSavedPost(userID, postID)
  local red = self:GetUserWriteConnection()
  local key = 'userSavedPost:'..userID

  local ok, err = red:sadd(key, postID)

  self:SetKeepalive(red)
  return ok, err

end

function userwrite:RemoveSavedPost(userID, postID)
  local red = self:GetUserWriteConnection()
  local key = 'userSavedPost:'..userID

  local ok, err = red:srem(key, postID)

  self:SetKeepalive(red)
  return ok, err

end


function userwrite:AddUserPostVotes(userID, createdAt, postID, direction)
  -- replace with bloom later
  local red = self:GetUserWriteConnection()
  local ok, err = red:zadd('userPostVotes:date:'..direction..':'..userID, createdAt, postID)
  if not ok then
    self:SetKeepalive(red)
    return ok, err
  end

  ok, err = red:sadd('userPostVotes:'..userID, postID)
  self:SetKeepalive(red)
  if not ok then
    ngx.log(ngx.ERR, 'unable to add user post vote: ',err)
  end
  return ok

end

function userwrite:AddUserAlert(createdAt,userID, alert)
  local red = self:GetUserWriteConnection()
  local ok, err = red:zadd('UserAlerts:'..userID,createdAt,alert)

  self:SetKeepalive(red)
  return ok, err
end

function userwrite:UpdateLastUserAlertCheck(userID, checkedAt)
  local red = self:GetUserWriteConnection()
  local ok, err = red:hmset('user:'..userID,'alertCheck',checkedAt)
  self:SetKeepalive(red)

  return ok, err
end

function userwrite:AddComment(commentInfo)
  local red = self:GetUserWriteConnection()
  local ok, err = red:zadd('userComments:date:'..commentInfo.createdBy, commentInfo.createdAt, commentInfo.postID..':'..commentInfo.id)
  ok, err = red:zadd('userComments:score:'..commentInfo.createdBy, commentInfo.score, commentInfo.postID..':'..commentInfo.id)
  return ok, err
end

function userwrite:CreateAccount(account)

  local red = self:GetUserWriteConnection()

  local hashedAccount = {}
  hashedAccount.sessions = {}
  hashedAccount.users = {}
  for k,v in pairs(account) do
    if k == 'sessions' then
      for _,session in pairs(v) do
        hashedAccount['session:'..session.id] = self:to_json(session)
      end
    elseif k == 'users' then
      for _,userID in pairs(v) do
        hashedAccount['user:'..userID] = userID
      end
    else
      hashedAccount[k] = v
    end
  end

  local ok, err = red:multi()
  if not ok then
    return ok, err
  end
   ok, err = red:del('account:'..hashedAccount.id)
   ok, err = red:hmset('account:'..hashedAccount.id,hashedAccount)
   ok, err = red:exec()
  return ok, err

end

function userwrite:AddSeenPosts(userID,seenPosts)
  local red = self:GetUserWriteConnection()
  local addKeySHA1 = addKey:GetSHA1()

  red:init_pipeline()
    for k,postID in pairs(seenPosts) do
      red:evalsha(addKeySHA1,0,userID,10000,0.01,postID)
      red:zadd('userSeen:'..userID,ngx.time(),postID)
    end
  local res,err = red:commit_pipeline()
  self:SetKeepalive(red)
  if err then
    ngx.log(ngx.ERR, 'unable to add seen post: ',err)
    return nil
  end
  return true
end

function userwrite:LabelUser(userID, targetUserID, label)
  local red = self:GetUserWriteConnection()

  local ok, err = red:hset('user:'..userID, 'userlabel:'..targetUserID, label)
  if err then
    ngx.log(ngx.ERR, 'unable to set user label')
  end
  return ok, err
end

function userwrite:IncrementUserStat(userID, statName, value)
  local red = self:GetUserWriteConnection()
  local ok, err = red:hincrby('user:'..userID, statName, value)
  self:SetKeepalive(red)
  return ok, err
end


function userwrite:IncrementAccountStat(userID, statName, value)
  local red = self:GetUserWriteConnection()
  local ok, err = red:hincrby('account:'..userID, statName, value)
  self:SetKeepalive(red)
  return ok, err
end

function userwrite:CreateSubUser(user)

  local hashedUser = {}
  hashedUser.filters = {}


  for k,v in pairs(user) do
    --print(k)
    if k == 'filters' then
      --do nothing for now, might add the hash later
    elseif k == 'commentSubscriptions' then
      hashedUser['commentSubscriptions:'] = to_json(v)
    elseif k == 'commentSubscribers' then
      hashedUser['commentSubscribers:'] = to_json(v)
    elseif k == 'postSubscriptions' then
      hashedUser['postSubscriptions:'] = to_json(v)
    elseif k == 'postSubscribers' then
      hashedUser['postSubscribers:'] = to_json(v)
    else
      hashedUser[k] = v
    end
  end

  local red = self:GetUserWriteConnection()
  hashedUser.filters = hashedUser.filters or {}

  red:init_pipeline()
    red:hmset('user:'..hashedUser.id, hashedUser)
    for _,filterID in pairs(hashedUser.filters) do
      red:sadd('userfilters:'..hashedUser.id,filterID)
    end
    red:hset('userToID',hashedUser.username:lower(),hashedUser.id)
  local results, err = red:commit_pipeline()
  self:SetKeepalive(red)

  if err then
    ngx.log(ngx.ERR, 'unable to create new user: ',err)
    return nil
  end
  return true

end

function userwrite:ToggleFilterSubscription(userID,filterID,subscribe)

  local red = self:GetUserWriteConnection()
  red:init_pipeline()
  if subscribe then
    red:sadd('userfilters:'..userID, filterID)
  else
    red:srem('userfilters:'..userID, filterID)
  end

  local ok, err = red:commit_pipeline()
  self:SetKeepalive(red)

  return ok, err
end


return userwrite
