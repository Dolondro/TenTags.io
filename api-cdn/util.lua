
local util = {}

util.locks = ngx.shared.locks


local app_helpers = require("lapis.application")
local assert_error, yield_error = app_helpers.assert_error, app_helpers.yield_error
local capture_errors, assert_error = app_helpers.capture_errors, app_helpers.assert_error
local to_json = (require 'lapis.util').to_json

local rateDict = ngx.shared.ratelimit
local routes = (require 'routes').routes
local roles = (require 'routes').roles
local userAPI = require 'api.users'


local filterStyles = {
  default = 'views.st.postelement',
  --minimal = 'views.st.postelement-min',
  HN = 'views.st.postelement-HN',
  full = 'views.st.postelement-full',
  grid = 'views.st.postelement-grid',
  --filtta = 'views.st.postelement-filtta'
}

util.filterStyles = filterStyles

function util:GetLock(key, lockTime)
  local success, err = self.locks:add(key, true, lockTime)
  if not success then
    if err ~= 'exists' then
      ngx.log(ngx.ERR, 'failed to add lock key: ',err)
    end
    return nil
  end
  return true
end

function util:RemLock(key)
  self.locks:delete(key)
end

function util.HandleError(request)
  ngx.log(ngx.ERR, to_json(request.errors))
  return {render = 'errors.general'}
end

function util.HandleJsonError(request)
  ngx.log(ngx.ERR, to_json(request.errors))
  return {json = {error = request.errors}, status = 400}
end

function util.RateLimit(request)

  local userID = ngx.ctx.userID

  if not userID then
	  yield_error('unkown user')
	end


  local route = routes[request.route_name]

  if not route then
    ngx.log(ngx.ERR, 'no ratelimiting for route: ', request.route_name)
    return true
  end

  -- we have a user and a routes
  local currentRole = roles.Public;
  if request.session.userID then
    currentRole = roles.User
  end

  if currentRole == roles.Public and route.access > roles.Public then
    return request:write({status = 401, render = 'pleaselogin'})
  end

  if request.userInfo and request.userInfo.role == 'Admin' then
    currentRole = roles.Admin
  end

  if currentRole == roles.User and route.access > roles.User then
    return request:write({status = 401, render = 'adminonly'})
  end

	local DISABLE_RATELIMIT = os.getenv('DISABLE_RATELIMIT')

	if DISABLE_RATELIMIT == 'true' then
		return
	end

	local key = request.route_name..userID
	local ok = rateDict:get(key)

	if not ok then
		assert_error(rateDict:set(key, 0, route.duration))
	end

	ok = assert_error(rateDict:incr(key,1))

	if ok < route.maxCalls then
		return ok
	else
		yield_error("You're doing that too much, please try again in a bit...")
	end

end


function util:GetScore(up,down)
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



function util:ConvertToUnique(jsonData)
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



 function util.TagColor(_,score)
  local offset = 100
  local r = offset+ math.floor((1 - score)*(255-offset))
  local g = offset+ math.floor(score*(255-offset))
  local b = 100
  return 'style="background-color: rgb('..r..','..g..','..b..')"'
end

function util.Paginate(request,params,direction)
  local startAt
  if direction == 'back' then
    startAt = params.startAt - 10
  elseif direction == 'forward' then
    params.startAt = params.startAt or 0
    startAt = params.startAt +10
  end
  local newParams = '?startAt='..startAt
  if params.sortBy then
    newParams = newParams..'&sortBy='..params.sortBy
  end
  return newParams
end

function util.GetStyleSelected(self, styleName)

  if not self.userInfo then
    return ''
  end

  local filterName = self.thisfilter and self.thisfilter.name or 'frontPage'

  if self.userInfo['filterStyle:'..filterName] and self.userInfo['filterStyle:'..filterName] == styleName then
    return 'selected="selected"'
  else
    return ''
  end

end

function util.UserHasFilter(self, filterID)
  if not self.session.userID then
    return false
  end
  for k,v in pairs(self.userFilters) do
    if v.id == filterID then
      return true
    end
  end
  return false

end

function util.TimeAgo(_,epochTime)
  local value, unit
  if epochTime < 60 then
    return 'Just now'
  elseif epochTime < 3600 then
    value, unit = math.floor(epochTime/60), 'minute'
  elseif epochTime < 86400 then
   value, unit = math.floor(epochTime/60/60), 'hour'
  elseif epochTime < 2592000 then
    value, unit = math.floor(epochTime/60/60/24), 'day'
  elseif epochTime < 31536000 then
    value, unit = math.floor(epochTime/60/60/24/30), 'month'
  else
    value, unit = math.floor(epochTime/60/60/24/365), 'year'
  end

  if value > 1 then
    return value..' '..unit..'s ago'
  else
    return value..' '..unit..' ago'
  end
end

function util.CalculateColor(name)
  local colors = { '#ffcccc', '#ccddff', '#ccffcc', '#ffccf2','lightpink','lightblue','lightyellow','lightgreen','lightred'};
  local sum = 0

  for i = 1, #name do
    sum = sum + (name:byte(i))
  end

  sum = sum % #colors + 1

  return 'style="background: '..colors[sum]..';"'

end


function util.GetFilterTemplate(self)

  local filterStyle = 'full'
  local filterName = self.thisfilter and self.thisfilter.name or 'frontPage'
  if self.session.userID then
    self.userInfo = self.userInfo or userAPI:GetUser(self.session.userID)
    if self.userInfo then
      --print('getting filter style for name: '..filterName,', ', self.userInfo['filterStyle:'..filterName])
      filterStyle = self.userInfo['filterStyle:'..filterName] or 'full'
    end
  else
    filterStyle = 'full'
  end

  if not filterStyles[filterStyle] then
    print('filter style not found: ',filterStyle)
    return filterStyles.default
  end
  return filterStyles[filterStyle]
end





--[[
function util:GetRedisConnectionFromSentinel(masterName, role)
  local redis_connector = require "resty.redis.connector"
  local rc = redis_connector.new()

  local redis, err = rc:connect{ url = "sentinel://"..masterName..":"..role, sentinels = sentinels }


  if not redis then
    ngx.log(ngx.ERR, 'error getting connection from master:', masterName, ', role: ',role, ', error: ', err)
    return nil
  else
    return redis
  end
end

function util:GetUserWriteConnection()
  return self:GetRedisConnectionFromSentinel('master-user', 'm')
end

function util:GetUserReadConnection()
  return self:GetRedisConnectionFromSentinel('master-user', 's')
end

function util:GetRedisReadConnection()
  return self:GetRedisConnectionFromSentinel('master-general', 's')
end

function util:GetRedisWriteConnection()
  return self:GetRedisConnectionFromSentinel('master-user', 'm')
end

function util:GetCommentWriteConnection()
  return self:GetRedisConnectionFromSentinel('master-user', 'm')
end

function util:GetCommentReadConnection()
  return self:GetRedisConnectionFromSentinel('master-user', 's')
end
--]]


return util
