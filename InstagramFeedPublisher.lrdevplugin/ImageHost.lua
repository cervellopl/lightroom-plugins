--[[----------------------------------------------------------------------------
ImageHost.lua
Uploads a rendered JPEG somewhere publicly reachable and returns its URL.

WHY THIS EXISTS
  The Instagram Graph API does NOT accept raw image bytes for feed photos. To
  create a media container you must hand it a *public https URL* that Meta's
  servers can fetch (`image_url`). So before we can publish, the rendered JPEG
  has to live at a real URL for a moment.

  This module implements that step against ImgBB, which needs only a free API
  key (no user login per upload). ImgBB also supports an `expiration` parameter,
  so we ask it to auto-delete the upload after a few minutes — Instagram only
  needs to read it once, during publishing, so there is nothing to clean up
  afterwards.

  It is deliberately small and single-purpose so a different host could be
  dropped in later without touching the publishing code.

Docs: https://api.imgbb.com/
------------------------------------------------------------------------------]]

local LrHttp = import 'LrHttp'
local LrStringUtils = import 'LrStringUtils'
local json = require 'json'

local ImageHost = {}

-- Seconds ImgBB keeps the upload before auto-deleting it. Instagram ingests the
-- image within seconds of container creation, so a few minutes is ample.
local EXPIRATION_SECONDS = 600

-- Upload a JPEG file to ImgBB.
--   jpegFilePath : path to a JPEG on disk.
--   apiKey       : ImgBB API key (free, from api.imgbb.com).
-- Returns (result, err) where result = { url = <direct image link> }.
function ImageHost.uploadImgbb(jpegFilePath, apiKey)

	if not apiKey or apiKey == '' then
		return nil, 'No ImgBB API key configured.'
	end

	-- ImgBB's documented upload format is base64 in an `image` field.
	local fh, ioErr = io.open(jpegFilePath, 'rb')
	if not fh then
		return nil, 'Could not read the rendered image: ' .. tostring(ioErr)
	end
	local bytes = fh:read('*all')
	fh:close()
	if not bytes or bytes == '' then
		return nil, 'The rendered image was empty.'
	end

	local b64 = LrStringUtils.encodeBase64(bytes):gsub('%s+', '')

	local url = string.format(
		'https://api.imgbb.com/1/upload?expiration=%d&key=%s', EXPIRATION_SECONDS, apiKey)

	local content = {
		{ name = 'image', value = b64 },
	}

	-- LrHttp.postMultipart( url, content, requestHeaders, timeout, ... )
	local body, respHeaders = LrHttp.postMultipart(url, content, nil, 60, nil, false)

	if not body then
		local status = respHeaders and respHeaders.error and respHeaders.error.name or 'unknown'
		return nil, 'Image upload failed (' .. tostring(status) .. ').'
	end

	local ok, parsed = pcall(json.decode, body)
	if not ok or type(parsed) ~= 'table' then
		return nil, 'Could not parse the image host response.'
	end

	local data = parsed.data
	if type(data) ~= 'table' or not (data.url or data.display_url) then
		local msg = 'unknown error'
		if type(parsed.error) == 'table' then
			msg = parsed.error.message or msg
		elseif parsed.status_txt then
			msg = parsed.status_txt
		end
		return nil, 'Image host rejected the upload: ' .. tostring(msg)
	end

	-- Instagram will not fetch over plain http; force https on the direct link.
	local link = tostring(data.url or data.display_url):gsub('^http://', 'https://')

	return { url = link }, nil
end

return ImageHost
