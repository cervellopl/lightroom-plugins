--[[----------------------------------------------------------------------------
InstagramAPI.lua
Wraps the Instagram Graph API's content-publishing endpoints.

Publishing a feed photo is a TWO-STEP flow (three for a carousel):
  1. Create a media *container* that references the image URL (+ caption):
        POST /{ig-user-id}/media   image_url=…&caption=…
     -> returns a container id (the "creation_id").
  2. Poll the container until its status_code is FINISHED.
  3. Publish it:
        POST /{ig-user-id}/media_publish   creation_id=…
     -> returns the published media id.

For a carousel (2–10 photos) each photo becomes a child container created with
is_carousel_item=true; a parent container with media_type=CAROUSEL and a
children= list ties them together, and the parent is what gets published.

Requirements (configured in plugin settings):
  * An Instagram *professional* account (Business or Creator) linked to a
    Facebook Page.
  * A User (or Page) access token with instagram_basic + instagram_content_publish.
  * The Instagram user id (a.k.a. IG Business Account ID).

Docs: https://developers.facebook.com/docs/instagram-api/guides/content-publishing
------------------------------------------------------------------------------]]

local LrHttp = import 'LrHttp'
local json = require 'json'

local InstagramAPI = {}

-- Bump this to move to a newer Graph API version.
local GRAPH_VERSION = 'v21.0'
local GRAPH_BASE = 'https://graph.facebook.com/' .. GRAPH_VERSION

--------------------------------------------------------------------------------
-- Small utilities
--------------------------------------------------------------------------------

local function urlencode(s)
	return (tostring(s):gsub('[^%w%-_%.~]', function(c)
		return string.format('%%%02X', string.byte(c))
	end))
end

local function formEncode(params)
	local parts = {}
	for k, v in pairs(params) do
		table.insert(parts, urlencode(k) .. '=' .. urlencode(v))
	end
	return table.concat(parts, '&')
end

-- Decode a Graph response and surface Meta's structured error if present.
-- Returns (table, nil) on success or (nil, message) on any error.
local function decodeResponse(body, respHeaders, whatFailed)
	if not body then
		local status = respHeaders and respHeaders.error and respHeaders.error.name or 'network error'
		return nil, whatFailed .. ' (' .. tostring(status) .. ').'
	end

	local ok, parsed = pcall(json.decode, body)
	if not ok or type(parsed) ~= 'table' then
		return nil, 'Could not parse the Instagram response.'
	end

	if parsed.error then
		local e = parsed.error
		local code = tonumber(e.code)
		-- Code 190 = the access token is invalid or expired. Short-lived tokens
		-- die within a couple of hours, so make the fix explicit.
		if code == 190 then
			return nil, 'The access token is invalid or has expired. In the Graph API '
				.. 'Explorer generate a new token, exchange it for a long-lived one '
				.. '(~60 days), and paste it into File ▸ Plug-in Manager ▸ '
				.. 'Instagram Feed Publisher.'
		end
		-- error_user_msg is the human-friendly text Meta wants shown to users.
		local msg = e.error_user_msg or e.message or 'unknown error'
		if e.code then msg = msg .. ' (code ' .. tostring(e.code) .. ')' end
		return nil, msg
	end

	return parsed, nil
end

local function post(path, params, whatFailed)
	local body, respHeaders = LrHttp.post(GRAPH_BASE .. path, formEncode(params), {
		{ field = 'Content-Type', value = 'application/x-www-form-urlencoded' },
		{ field = 'Accept', value = 'application/json' },
	})
	return decodeResponse(body, respHeaders, whatFailed)
end

local function get(path, params, whatFailed)
	local url = GRAPH_BASE .. path .. '?' .. formEncode(params)
	local body, respHeaders = LrHttp.get(url, {
		{ field = 'Accept', value = 'application/json' },
	}, 30)
	return decodeResponse(body, respHeaders, whatFailed)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Confirm the token + account id work and return the account's @username.
-- Returns (username, nil) or (nil, message).
function InstagramAPI.verify(token, igUserId)
	if not token or token == '' then return nil, 'No access token configured.' end
	if not igUserId or igUserId == '' then return nil, 'No Instagram account id configured.' end

	local res, err = get('/' .. igUserId, {
		fields = 'username',
		access_token = token,
	}, 'Verification request failed')
	if not res then
		-- Code 12 ("username field is deprecated") is what the Graph API returns
		-- when the id points at a Facebook user/Page node rather than an
		-- Instagram Business Account node.
		local e = tostring(err)
		if e:find('deprecated') or e:find('#12') then
			return nil, 'That id is not an Instagram Business Account id — it looks like a '
				.. 'Facebook user or Page id. Click "Find my account id" to fetch the right one.'
		end
		return nil, err
	end

	if not res.username then
		return nil, 'The account id did not resolve to an Instagram username. '
			.. 'Use "Find my account id", or check that the id is the Instagram '
			.. 'Business Account id, not the Facebook Page id.'
	end
	return res.username, nil
end

-- Discover the Instagram Business accounts reachable from this token by walking
-- the user's Facebook Pages (each Page may link one Instagram account).
-- Returns (accounts, nil) where accounts is an array of
--   { pageName=, igId=, igUsername= }   (only entries that HAVE a linked IG
-- account are included), or (nil, message).
function InstagramAPI.discoverAccounts(token)
	if not token or token == '' then return nil, 'No access token configured.' end

	local res, err = get('/me/accounts', {
		fields = 'name,instagram_business_account{id,username}',
		limit = '100',
		access_token = token,
	}, 'Looking up your Facebook Pages failed')
	if not res then return nil, err end

	local accounts = {}
	if type(res.data) == 'table' then
		for _, page in ipairs(res.data) do
			local iga = page.instagram_business_account
			if type(iga) == 'table' and iga.id then
				table.insert(accounts, {
					pageName = page.name or '',
					igId = iga.id,
					igUsername = iga.username or '',
				})
			end
		end
	end
	return accounts, nil
end

-- Create a single-image media container.
--   isCarouselItem : when true the container is a carousel child (no caption).
-- Returns (containerId, nil) or (nil, message).
function InstagramAPI.createImageContainer(token, igUserId, imageUrl, caption, isCarouselItem)
	local params = {
		image_url = imageUrl,
		access_token = token,
	}
	if isCarouselItem then
		params.is_carousel_item = 'true'
	elseif caption and caption ~= '' then
		params.caption = caption
	end

	local res, err = post('/' .. igUserId .. '/media', params, 'Creating the media container failed')
	if not res then return nil, err end
	if not res.id then return nil, 'Instagram did not return a container id.' end
	return res.id, nil
end

-- Create a CAROUSEL parent container tying children together.
--   childIds : array of container ids (2–10) from createImageContainer(...,true).
-- Returns (containerId, nil) or (nil, message).
function InstagramAPI.createCarouselContainer(token, igUserId, childIds, caption)
	local params = {
		media_type = 'CAROUSEL',
		children = table.concat(childIds, ','),
		access_token = token,
	}
	if caption and caption ~= '' then params.caption = caption end

	local res, err = post('/' .. igUserId .. '/media', params, 'Creating the carousel container failed')
	if not res then return nil, err end
	if not res.id then return nil, 'Instagram did not return a carousel container id.' end
	return res.id, nil
end

-- Read a container's processing status.
-- Returns (statusCode, nil) where statusCode is one of
-- EXPIRED | ERROR | FINISHED | IN_PROGRESS | PUBLISHED, or (nil, message).
function InstagramAPI.getContainerStatus(token, containerId)
	local res, err = get('/' .. containerId, {
		fields = 'status_code',
		access_token = token,
	}, 'Checking the upload status failed')
	if not res then return nil, err end
	return res.status_code or 'IN_PROGRESS', nil
end

-- Publish a finished container.
-- Returns (mediaId, nil) or (nil, message).
function InstagramAPI.publish(token, igUserId, creationId)
	local res, err = post('/' .. igUserId .. '/media_publish', {
		creation_id = creationId,
		access_token = token,
	}, 'Publishing failed')
	if not res then return nil, err end
	if not res.id then return nil, 'Instagram did not return a published media id.' end
	return res.id, nil
end

-- Fetch the public permalink of a published media item (best effort).
-- Returns (permalink, nil) or (nil, message).
function InstagramAPI.getPermalink(token, mediaId)
	local res, err = get('/' .. mediaId, {
		fields = 'permalink',
		access_token = token,
	}, 'Fetching the permalink failed')
	if not res then return nil, err end
	return res.permalink, nil
end

return InstagramAPI
