
--[[ test how much room posts will take up in redis sorted set
      if we just store the id
      need one sorted set for score, another for date

      can probably store all post ids in redis
      will either need to LRU post data and comment data or archive

	100k comments in cjson and hashes: 50mb

	100k comments as objects in hashes: 138mb

	1.7billion reddit comments to date
	= 850 gb ram


--]]

local ffi = require("ffi")
ffi.cdef[[
	typedef long time_t;

 	typedef struct timeval {
		time_t tv_sec;
		time_t tv_usec;
	} timeval;

	int gettimeofday(struct timeval* t, void* tzp);
]]

local gettimeofday_struct = ffi.new("timeval")

local function gettimeofday()
 	ffi.C.gettimeofday(gettimeofday_struct, nil)
 	return tonumber(gettimeofday_struct.tv_sec) * 1000000 + tonumber(gettimeofday_struct.tv_usec)
end


local redis = require 'redis'
local client = redis.connect('127.0.0.1', 6379)
local random = math.random
local tinsert = table.insert
local uuid = require 'uuid'
local cjson = require 'cjson'

function string.fromhex(str)
    return (str:gsub('..', function (cc)
        return string.char(tonumber(cc, 16))
    end))
end

function TestReadBit()
  client:del('testkey')
  for i = 1, 40 do


    client:setbit('testkey',i,1)
    local value = client:get('testkey')

    print(i,string.format('%q', value))
  end
end
--TestReadBit()

function TestPost()
  --[[
    each post needs a sorted set by date,
    a sorted set by score
    a set of tags
    a hash of properties
  ]]
  local post = {}
  local tags = {}
  local params = {}
  local comments = {}
  local count = 0
  for i = 1,1000000 do
    if i % 10000 == 0 then
      print(i)
    end
    client:pipeline(function(p)
        count = count + 1
        params = {}
        post = {}
        post.id = 'postidbutshouldremainabought'..i
        tags = {}
        comments = {}
        for j = 5,5+random(10)do
          tinsert(tags,'etnlongpostid approaching32cha'..j)
        end
        for j = 1,20 do
          tinsert(params,'randomstatorparam'..j)
        end
        for j = 1,200 do
          tinsert(comments,'some long commment that hopefully is an average size comment some long commment that hopefully is an average size commentsome long commment that hopefully is an average size commentsome long commment that hopefully is an average size comment')
        end
        p:zadd('posts:score',i,post.id)
        p:zadd('posts:date',i,post.id)
        p:sadd('post:tags:'..post.id, unpack(tags))
        p:hmset('postinfo:'..post.id, unpack(params))
        p:sadd('post:comments:'..post.id, unpack(comments))

    end)
  end
  print(count)
end

function TestPostNoComments()
  --[[
    each post needs a sorted set by date,
    a sorted set by score
    a set of tags
    a hash of properties
  ]]
  local post = {}
  local tags = {}
  local params = {}
  local count = 0
  for i = 1,100000 do
    if i % 10000 == 0 then
      print(i)
    end
    client:pipeline(function(p)
        count = count + 1
        params = {}
        post = {}
        post.id = 'postidbutshouldremainabought'..i
        tags = {}
        for j = 5,5+random(10)do
          tinsert(tags,'etnlongpostid approaching32cha'..j)
        end
        for j = 1,20 do
          tinsert(params,'randomstatorparam'..j)
        end
        p:zadd('posts:score',i,post.id)
        p:zadd('posts:date',i,post.id)
        p:sadd('post:tags:'..post.id, unpack(tags))
        p:hmset('postinfo:'..post.id, unpack(params))

    end)
  end
  print(count)
end

local function TestComments()
  --138meg
  local comment = {}
  for i = 1, 100000 do
    if i % 10000 == 0 then
      print(i)
    end
    comment = {}
    comment.id = 'ariosetnoairsenoiarestaiorseooia'..i
    comment.text = 'aernstoiearnstioeranstioernstiearnstoiestnaioresiaorsenarsitonsrtatraernstoiearnstioeranstioernstiearnstoiestnaioresiaorsenarsitonsrtatraernstoiearnstioeranstioernstiearnstoiestnaioresiaorsenarsitonsrtatr'
    comment.up = random(1000)
    comment.down =  random(1000)
    comment.userid = 'oairestoiarsetoairoseniarestn'..i
    comment.postID = 'oairestoiarsetoairoeniarestn'..i
    client:pipeline(function(p)
      p:hset('comment:'..comment.id,'id',comment.id)
      p:hset('comment:'..comment.id,'text',comment.text)
      p:hset('comment:'..comment.id,'up',comment.up)
      p:hset('comment:'..comment.id,'down',comment.down)
      p:hset('comment:'..comment.id,'userid',comment.userid)
      p:hset('comment:'..comment.id,'postID',comment.postID)

      p:zadd('post'..(i/10)..'comment:date',i,comment.id)
      p:zadd('post'..(i/10)..'comment:score',i,comment.id)
    end)
  end
end
--TestComments()

local function TestSerialComments()
  --49.29 meg
  -- 14 seconds raw
  -- 2.75 pipelined 1000 at a time


  local comment = {}
  local start = gettimeofday()

  for i = 1, 100000 do
    if i % 1000 == 0 then
      print(i)
    end
    client:pipeline(function(p)

        comment = {}
        comment.id = 'ariosetnoairsenoiarestaiorseooia'..i
        comment.text = 'aernstoiearnstioeranstioernstiearnstoiestnaioresiaorsenarsitonsrtatraernstoiearnstioeranstioernstiearnstoiestnaioresiaorsenarsitonsrtatraernstoiearnstioeranstioernstiearnstoiestnaioresiaorsenarsitonsrtatr'
        comment.up = random(1000)
        comment.down =  random(1000)
        comment.userid = 'oairestoiarsetoairoseniarestn'..i
        comment.postID = 'oairestoiarsetoairoeniarestn'..i
        local serialComment = cjson.encode(comment)

        p:hmset('winweofinweofinwefwefe',comment.id,serialComment)

    end)
  end
  start = gettimeofday()
  local res = client:hgetall('winweofinweofinwefwefe')
  local i = 1
  for k,v in pairs(res) do
    local comment = cjson.decode(v)
    i = i+1
  end
  print(i)


  local endTime = gettimeofday()
  print(endTime - start)
end
--TestSerialComments()

local function TestInMemory()
	local comment
	local allPosts = {}
	for i = 1, 100000 do
		if i % 10000 == 0 then
      print(i)
			print(string.format(" GC size: %.3f KB", collectgarbage("count")))
    end
		comment = {}
		comment.id = 'ariosetnoairsenoiarestaiorseooia'..i
		comment.text = 'aernstoiearnstioeranstioernstiearnstoiestnaioresiaorsenarsitonsrtatraernstoiearnstioeranstioernstiearnstoiestnaioresiaorsenarsitonsrtatraernstoiearnstioeranstioernstiearnstoiestnaioresiaorsenarsitonsrtatr'
		comment.up = random(1000)
		comment.down =  random(1000)
		comment.userid = 'oairestoiarsetoairoseniarestn'..i
		comment.postID = 'oairestoiarsetoairoeniarestn'..i
		table.insert(allPosts,comment)
	end

end
TestInMemory()

local function TestSpeed()


end



function TestRedisKeys()
  local new = uuid.new
  local uuid
  client:pipeline(function(p)
    for i = 1, 100000 do
      if i % 10000 == 0 then
        print(i)
      end
      p:sadd(i,'testkeys')
    end
  end)
end
--TestRedisKeys()


--TestComments()
--TestPostNoComments()

--[[
function testposts()
  for i = 1, 1000000 do
    client:zadd('posts',i,i)
  end
  -- 1 million id's = 104 meg used
end



function commentSize()
  local string10k = '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'
  -- 100,000 10k character strings use 1.15GB ram
  local string1k = 'WWrcVigJ7up1YujZsqSvqFtjZUZ0ORanfPiPHTS32wiJRxyatot25FAjJU7Pj7fsjnlAQxuYohDsSBFCNmRO00ya6S4UHGF1J8PbJNpqAmkhW4B32B9fI9fXCA37VgezUcAzXpEOlb05w0J5OyyPBmM65zpXeCx4WuP62e2SbFvD2DjlSukkLIINcnCrY8Mo97CJ1zXvlCZNjeGM6jNpJjlgn7BhUoAIvn89kxHXSCJz0g30DBoA3zfIbh60Oycit7Tl3ughS3BtTOg5qqyPMbWcWtB7wJ4DpNyFGoyaS2sRvbgUEbxGDQXf4TeJWX2hn8PM7AVjE3pPbAFFq7SYnbOkqN0TIYJQVhFlGVX7N9Wfm7Sp2V4Xz7Jv8xgDio745ebzbYhP2SZOOQrU328PV2X7uJ6JXlKrsemHoZ7Yvi8VH8KLymWHb4XPHeF3Uqb6kb8fh1XeTZsCx5Z7fSr0jCm98b491oCN8I9p2rzrmQOMYS3EqWVwpgcBEuA6sUlPqDqjUOxK3M7yYG1moFq3N1DUTzo5pVl284HTLbzKmqMbqmxm0DM1qBfxJPgWjcqSmRJINM0FhtVQYovKqEz4MF1hh0wDwzTmMFD9kvDWh8sfVl70LTZIfYLQcpkVSrzz9KNo58vXn9b9fVo647XoHGSy2EqAAJcZ5kYsmMO1E19Kx9vl4sQEHoKm1P0b8SUHL6f3kUYrG3tLVinnCniH1LPV6gTCwEuuRZqtjAVePPgN5icwcQYovPJ7inAFfXrlSxpeaAJxl0yPOL30loX2hjETj0xqGJgavDnzgNJJaL0wjVstORFM1uglfeIDmxwPsFNJqbi70nMHgZ1TTnOtZKkAOU04RO9JNUXFMLng0ISSMjVv1YfyfJXc5i9axTGqJBMZcwIakUaI4JtJCZw1ucqa3LOycES8nTxVwqWcnKHbCKWnp2pcIpaS5A7nLEBy2tDO3negqtK33flsmnoOaG7nk5eGQAnZU7xfM5g4'
  -- 1,000,000 1k character strings use 1.02GB ram
  for i = 1, 1000000 do
    client:set(i,string1k)
  end

end

function voteSize()

  for i = 1, 1000000 do
    client:set('comments'..i,'(1000000,,1)')
  end
  -- 1 million votes uses 115.2MBram

end

voteSize()
--]]
