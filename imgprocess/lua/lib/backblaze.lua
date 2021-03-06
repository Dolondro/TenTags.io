local sha1 = require 'sha1'


local cjson = require('cjson')
local ltn12 = require("ltn12")
require("socket")
local https = require 'ssl.https'



local bucketID = os.getenv('BB_BUCKETID')

local socket = require 'socket'

local bb = {}
local authToken
local apiUrl
local authedAt
local uploadAuthedAt, uploadToken, uploadUrl
local downloadUrl



local encode_base64 = ngx and ngx.encode_base64 or require ('lib.base64').enc


local accountID, authKey = os.getenv('BB_ACCOUNTID'), os.getenv('BB_KEY')
if not accountID then
  print( 'couldnt find backblaze account id in env variable')
end
if not authKey then
  print( 'couldnt find backblaze account id in env variable')
end



local function GetHash(values)
  return sha1(values)
end

function bb:GetAuthToken()
  local currTime = os.time()
  if authedAt and authedAt > (currTime - 86400) then
    return true
  end


  local authUrl = 'https://api.backblaze.com/b2api/v1/b2_authorize_account'
  local authstring = 'Basic '..encode_base64(accountID..':'..authKey)
  local sink = {}
  local r, c, h = https.request{
    url = authUrl,
    method = 'GET',
    sink = ltn12.sink.table(sink),
    headers = {
      Authorization = authstring
    },
    protocol = "tlsv1"
  }
  if not r then
    print('no r')
    print(c, cjson.encode(h),cjson.encode(table.concat(sink)))
    return r, c
  end

  if (c ~= 200) then
    print('code not 200: ',c)
    print(c, cjson.encode(h),cjson.encode(table.concat(sink)))
    return nil, 'failed to auth: '..c
  end

  authedAt = currTime

  local body = cjson.decode(table.concat(sink))
  apiUrl = body.apiUrl
  authToken = body.authorizationToken
  downloadUrl = body.downloadUrl

  return true

end

function bb:GetDownloadUrl()
  if not downloadUrl then
    local ok, err = self:GetAuthToken()
    if not ok then
      return ok, err
    end
  end

  return downloadUrl
end

function bb:GetUploadUrl()
  local currTime = os.time()
  if uploadAuthedAt and uploadAuthedAt > (currTime - 86400) then
    return true
  end
  local sink = {}
  local jsonned = cjson.encode({bucketId = bucketID})
  print(apiUrl)
  local r, c, h = https.request{
    url = apiUrl..'/b2api/v1/b2_get_upload_url',
    method = 'POST',
    headers = {
      Authorization = authToken,
      ['content-length'] = #jsonned
    },
    sink = ltn12.sink.table(sink),
    source=ltn12.source.string(jsonned),
    protocol = "tlsv1"
  }
  if not r then
    print('couldnt get r')
    print(c, cjson.encode(h), cjson.encode(table.concat(sink)))
    return r, c
  end
  if (c ~= 200) then
    print('code not 200:',c)
    print(c, cjson.encode(h), cjson.encode(table.concat(sink)))
    return nil, 'failed to auth uplaod url: '
  end

  uploadAuthedAt = currTime

  local body = cjson.decode(table.concat(sink))
  uploadToken = body.authorizationToken
  uploadUrl = body.uploadUrl
  return true
end

function bb:Upload(fileName, fileContent)
  local sink = {}
  local content = fileContent
  local r,c,h = https.request{
    url = uploadUrl,
    method = 'POST',
    headers = {
      Authorization = uploadToken,
      ['X-Bz-File-Name'] = fileName,
      ['Content-Type'] = 'b2/x-auto',
      ['Content-Length'] = #content,
      ['X-Bz-Content-Sha1'] = GetHash(content)

    },
    sink = ltn12.sink.table(sink),
    source=ltn12.source.string(content),
    protocol = "tlsv1"
  }
  if not r then
    print('not r in upload', c)
    print(r,c)
    return r,c
  end

  if (c ~= 200) then
    print('c not 200, ', c, cjson.encode(h), cjson.encode(table.concat(sink)))
    return nil, 'failed to auth: '
  end
  local body = cjson.decode(table.concat(sink))
  return body.fileId
end

function bb:UploadImage(fileContent, fileName)
  -- check filename

  local ok, err = self:GetAuthToken()
  if not ok then
    print('couldnt auth')
    print( ok, err)
    return nil, err
  end
  print('got auth')

  print('getting upload url')
  ok, err = self:GetUploadUrl()
  if not ok then
    print(ok, err)
    return nil, err
  end
  print('got upload url')

  print('uploading')
  ok, err = self:Upload(fileName, fileContent)
  if not ok then
    print(ok, err)
    return nil, err
  end
  print('uploaded')

  return ok

end

function bb:GetImageFromBB(imageID)

  print(downloadUrl..'?fileId='..imageID)
  local sink = {}
  local r,c,h = https.request{
    url = downloadUrl..'/b2api/v1/b2_download_file_by_id?fileId='..imageID,

    headers = {
      Authorization = authToken,
    },
    sink = ltn12.sink.table(sink)
  }
  if not r then
    print(c, cjson.encode(h))
    return r, c
  end

  if c ~= 200 then
    print(c,cjson.encode(h))
    return nil, c
  end
  --print(to_json(res))
  local imageInfo = {
    ['Content-Type'] = h['Content-Type'],
    filename = h['x-bz-file-name'],
    data = table.concat(sink)
  }

  return imageInfo
end

function bb:GetImage(imageID)

  local ok, err = self:GetAuthToken()
  if not ok then
    print(ok, err)
    return nil, err
  end

  ok, err = self:GetImageFromBB(imageID)
  return ok, err
end

return bb
