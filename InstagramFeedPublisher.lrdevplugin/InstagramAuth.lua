--[[----------------------------------------------------------------------------
InstagramAuth.lua
Keeps the Facebook/Instagram access token alive so it never silently expires.

HOW META TOKENS WORK
  * A token from the Graph API Explorer is *short-lived* (~1-2 h).
  * You exchange it once for a *long-lived* token (~60 days) using the app's
    App ID + App Secret (grant_type=fb_exchange_token).
  * You can keep exchanging a still-valid long-lived token for a NEW long-lived
    token, each time resetting the ~60-day clock. So as long as the plugin
    refreshes before the current token lapses, the connection never expires.

This module:
  * makeLongLived()   – turn the pasted token into a long-lived one (one click).
  * ensureFreshToken() – called before every publish/verify; transparently
    re-exchanges the token when it is missing an expiry or getting close to it,
    and stores the new token + expiry. If it can't refresh (no App
    credentials, or the exchange fails) it returns the current token unchanged.

Requires the App ID + App Secret from  Meta app ▸ Settings ▸ Basic.
------------------------------------------------------------------------------]]

local LrHttp = import 'LrHttp'
local LrPrefs = import 'LrPrefs'
local json = require 'json'

local prefs = LrPrefs.prefsForPlugin()

local GRAPH_VERSION = 'v21.0'
local GRAPH_BASE = 'https://graph.facebook.com/' .. GRAPH_VERSION

-- Refresh once the token has less than this much life left (10 days).
local REFRESH_WHEN_REMAINING = 10 * 24 * 60 * 60

local InstagramAuth = {}

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

function InstagramAuth.hasAppCredentials()
	return prefs.igAppId and prefs.igAppId ~= ''
		and prefs.igAppSecret and prefs.igAppSecret ~= ''
end

-- Exchange a short- OR long-lived token for a fresh long-lived one.
-- Returns (token, expiresInSeconds) or (nil, errorMessage).
local function exchange(token)
	local url = GRAPH_BASE .. '/oauth/access_token?' .. formEncode {
		grant_type = 'fb_exchange_token',
		client_id = prefs.igAppId,
		client_secret = prefs.igAppSecret,
		fb_exchange_token = token,
	}

	local body = LrHttp.get(url, { { field = 'Accept', value = 'application/json' } }, 30)
	if not body then
		return nil, 'Token exchange request failed (network error).'
	end

	local ok, parsed = pcall(json.decode, body)
	if not ok or type(parsed) ~= 'table' then
		return nil, 'Could not parse the token-exchange response.'
	end
	if parsed.error then
		local e = parsed.error
		local msg = e.error_user_msg or e.message or 'unknown error'
		if e.code then msg = msg .. ' (code ' .. tostring(e.code) .. ')' end
		return nil, msg
	end
	if not parsed.access_token then
		return nil, 'The token-exchange response contained no access token.'
	end
	return parsed.access_token, tonumber(parsed.expires_in)
end

local function store(token, expiresIn)
	prefs.igAccessToken = token
	prefs.igTokenObtainedAt = os.time()
	prefs.igTokenExpiresAt = expiresIn and (os.time() + expiresIn) or nil
end

-- One-click: convert the currently pasted token into a long-lived token.
-- Returns (true) or (false, errorMessage).
function InstagramAuth.makeLongLived()
	if not InstagramAuth.hasAppCredentials() then
		return false, 'Enter the App ID and App Secret first (Meta app ▸ Settings ▸ Basic).'
	end
	if not (prefs.igAccessToken and prefs.igAccessToken ~= '') then
		return false, 'Paste an access token first.'
	end

	local token, expiresIn = exchange(prefs.igAccessToken)
	if not token then return false, expiresIn end

	store(token, expiresIn)
	return true
end

-- Called before publish/verify. Refreshes the token when it is missing an
-- expiry or nearing it, then returns a usable token. Returns (token, err);
-- err is only set when there is no token at all.
function InstagramAuth.ensureFreshToken()
	local token = prefs.igAccessToken
	if not token or token == '' then
		return nil, 'No access token configured.'
	end

	-- Without App credentials we can't refresh — use whatever we have.
	if not InstagramAuth.hasAppCredentials() then
		return token
	end

	local expiresAt = prefs.igTokenExpiresAt
	local needsRefresh = (not expiresAt) or ((expiresAt - os.time()) < REFRESH_WHEN_REMAINING)
	if not needsRefresh then
		return token
	end

	local newToken, expiresIn = exchange(token)
	if not newToken then
		-- Refresh failed (e.g. token already dead). Keep the current one so the
		-- caller can surface Meta's own error when it actually uses it.
		return token
	end

	store(newToken, expiresIn)
	return newToken
end

-- Human-readable token lifetime for the settings panel.
function InstagramAuth.tokenStatus()
	if not (prefs.igAccessToken and prefs.igAccessToken ~= '') then
		return 'No token set'
	end
	if prefs.igTokenExpiresAt then
		local secs = prefs.igTokenExpiresAt - os.time()
		if secs <= 0 then return 'Token expired — refresh it' end
		local days = math.floor(secs / 86400)
		if days >= 2 then
			return string.format('Long-lived token — auto-refreshes (~%d days left)', days)
		end
		return string.format('Token expires in ~%d h — refresh it', math.floor(secs / 3600))
	end
	return 'Token set (short-lived?) — click "Get long-lived token"'
end

return InstagramAuth
