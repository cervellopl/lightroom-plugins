--[[----------------------------------------------------------------------------
ImageHost.lua
Uploads a rendered JPEG somewhere publicly reachable and returns its URL.

WHY THIS EXISTS
  The Instagram Graph API does NOT accept raw image bytes for feed photos. To
  create a media container you must hand it a *public https URL* that Meta's
  servers can fetch (`image_url`). So before we can publish, the exported JPEG
  has to live at a real URL for a moment.

  This module implements that step against Imgur's anonymous upload API, which
  only needs a free "Client ID" (no user login). Imgur returns a direct
  https://i.imgur.com/… link that Instagram can read.

  It is deliberately small and single-purpose so a different host could be
  dropped in later without touching the publishing code.

Docs: https://apidocs.imgur.com/  ->  POST /3/image
------------------------------------------------------------------------------]]

local LrHttp = import 'LrHttp'
local json = require 'json'

local ImageHost = {}

local IMGUR_UPLOAD_URL = 'https://api.imgur.com/3/image'

-- Upload a JPEG file to Imgur anonymously.
--   jpegFilePath : path to a JPEG on disk.
--   clientId     : Imgur application Client ID (free, from imgur.com).
-- Returns (result, err) where result = { url = <direct link>,
-- deleteHash = <token> }.  deleteHash lets us remove the temporary upload
-- after Instagram has ingested it.
function ImageHost.uploadImgur(jpegFilePath, clientId)

	if not clientId or clientId == '' then
		return nil, 'No Imgur Client ID configured.'
	end

	local content = {
		{ name = 'type', value = 'file' },
		{
			name = 'image',
			fileName = 'photo.jpg',
			filePath = jpegFilePath,
			contentType = 'image/jpeg',
		},
	}

	local headers = {
		{ field = 'Authorization', value = 'Client-ID ' .. clientId },
		{ field = 'Accept', value = 'application/json' },
	}

	-- LrHttp.postMultipart( url, content, requestHeaders, timeout, ... )
	local body, respHeaders = LrHttp.postMultipart(IMGUR_UPLOAD_URL, content, headers, 60, nil, false)

	if not body then
		local status = respHeaders and respHeaders.error and respHeaders.error.name or 'unknown'
		return nil, 'Image upload failed (' .. tostring(status) .. ').'
	end

	local ok, parsed = pcall(json.decode, body)
	if not ok or type(parsed) ~= 'table' then
		return nil, 'Could not parse the image host response.'
	end

	if parsed.success == false or type(parsed.data) ~= 'table' or not parsed.data.link then
		local msg = 'unknown error'
		if type(parsed.data) == 'table' and parsed.data.error then
			-- Imgur reports the error either as a string or a nested object.
			msg = type(parsed.data.error) == 'table'
				and (parsed.data.error.message or parsed.data.error.code)
				or parsed.data.error
		end
		return nil, 'Image host rejected the upload: ' .. tostring(msg)
	end

	-- Instagram will not fetch over plain http; force https on the direct link.
	local url = tostring(parsed.data.link):gsub('^http://', 'https://')

	return {
		url = url,
		deleteHash = parsed.data.deletehash,
	}, nil
end

-- Best-effort cleanup of a temporary anonymous upload. Failure is ignored on
-- purpose — a leftover image is harmless and Instagram already has its copy.
function ImageHost.deleteImgur(deleteHash, clientId)
	if not deleteHash or deleteHash == '' or not clientId or clientId == '' then
		return
	end
	local headers = {
		{ field = 'Authorization', value = 'Client-ID ' .. clientId },
	}
	pcall(function()
		LrHttp.post('https://api.imgur.com/3/image/' .. deleteHash, '', headers, 'DELETE')
	end)
end

return ImageHost
