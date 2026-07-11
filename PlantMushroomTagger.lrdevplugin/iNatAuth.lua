--[[----------------------------------------------------------------------------
iNatAuth.lua
OAuth 2.0 handling for iNaturalist, with automatic API-token refresh.

iNaturalist has TWO tokens:
  1. An OAuth *access token* obtained once via the Authorization Code flow.
     iNaturalist access tokens are long-lived; if a refresh token is issued we
     use it to renew silently when the access token is ever rejected.
  2. A short-lived *API JWT* (~24 h) required by the api.inaturalist.org
     endpoints (including computer vision). It is fetched from
     https://www.inaturalist.org/users/api_token using the access token.

This module caches the API JWT and transparently re-fetches it when stale or
rejected, so the user authorizes only once.

Setup the user does once:
  * Register an app at https://www.inaturalist.org/oauth/applications/new
    with redirect URI  urn:ietf:wg:oauth:2.0:oob  (out-of-band / copy-paste).
  * Paste the resulting Client ID + Client Secret into plugin settings and
    click "Authorize…".
------------------------------------------------------------------------------]]

local LrHttp = import 'LrHttp'
local LrPrefs = import 'LrPrefs'
local json = require 'json'

local prefs = LrPrefs.prefsForPlugin()

local REDIRECT_URI = 'urn:ietf:wg:oauth:2.0:oob'
local AUTHORIZE_URL = 'https://www.inaturalist.org/oauth/authorize'
local TOKEN_URL = 'https://www.inaturalist.org/oauth/token'
local API_TOKEN_URL = 'https://www.inaturalist.org/users/api_token'

-- Re-fetch the JWT once it is older than this (it lasts ~24 h).
local API_TOKEN_MAX_AGE = 23 * 60 * 60

local iNatAuth = {}

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

local function httpStatus(headers)
	if not headers then return nil end
	if headers.status then return tonumber(headers.status) end
	-- Some SDK builds expose it via the raw status line only.
	return nil
end

--------------------------------------------------------------------------------
-- State helpers
--------------------------------------------------------------------------------

function iNatAuth.hasCredentials()
	return prefs.inatClientId and prefs.inatClientId ~= ''
		and prefs.inatClientSecret and prefs.inatClientSecret ~= ''
end

-- Usable if OAuth-authorized OR a manual JWT was pasted (legacy fallback).
function iNatAuth.isConfigured()
	return (prefs.inatAccessToken and prefs.inatAccessToken ~= '')
		or (prefs.inatToken and prefs.inatToken ~= '')
end

function iNatAuth.isAuthorized()
	return prefs.inatAccessToken and prefs.inatAccessToken ~= ''
end

function iNatAuth.signOut()
	prefs.inatAccessToken = nil
	prefs.inatRefreshToken = nil
	prefs.inatApiToken = nil
	prefs.inatApiTokenFetchedAt = nil
end

function iNatAuth.buildAuthorizeUrl()
	return AUTHORIZE_URL
		.. '?client_id=' .. urlencode(prefs.inatClientId or '')
		.. '&redirect_uri=' .. urlencode(REDIRECT_URI)
		.. '&response_type=code'
end

--------------------------------------------------------------------------------
-- OAuth token exchange / refresh
--------------------------------------------------------------------------------

local function requestToken(params)
	local headers = {
		{ field = 'Content-Type', value = 'application/x-www-form-urlencoded' },
		{ field = 'Accept', value = 'application/json' },
	}
	local body, respHeaders = LrHttp.post(TOKEN_URL, formEncode(params), headers)
	if not body then
		local n = respHeaders and respHeaders.error and respHeaders.error.name or 'network error'
		return nil, 'Token request failed (' .. tostring(n) .. ').'
	end

	local ok, parsed = pcall(json.decode, body)
	if not ok or type(parsed) ~= 'table' then
		return nil, 'Could not parse token response.'
	end
	if parsed.error then
		return nil, 'OAuth error: ' .. tostring(parsed.error_description or parsed.error)
	end
	if not parsed.access_token then
		return nil, 'OAuth response contained no access token.'
	end
	return parsed, nil
end

-- Exchange the copy-pasted authorization code for an access token.
-- Returns true on success, or (false, errorMessage).
function iNatAuth.exchangeCodeForToken(code)
	if not iNatAuth.hasCredentials() then
		return false, 'Enter the Client ID and Client Secret first.'
	end
	if not code or code == '' then
		return false, 'No authorization code supplied.'
	end

	local tok, err = requestToken {
		grant_type = 'authorization_code',
		code = code,
		client_id = prefs.inatClientId,
		client_secret = prefs.inatClientSecret,
		redirect_uri = REDIRECT_URI,
	}
	if not tok then return false, err end

	prefs.inatAccessToken = tok.access_token
	prefs.inatRefreshToken = tok.refresh_token -- may be nil; that's fine
	prefs.inatApiToken = nil                    -- force a fresh JWT next call
	prefs.inatApiTokenFetchedAt = nil
	return true, nil
end

-- Try to renew the access token using a stored refresh token.
local function refreshAccessToken()
	if not prefs.inatRefreshToken or prefs.inatRefreshToken == '' then
		return false, 'Session expired and no refresh token is available — please Authorize again.'
	end
	local tok, err = requestToken {
		grant_type = 'refresh_token',
		refresh_token = prefs.inatRefreshToken,
		client_id = prefs.inatClientId,
		client_secret = prefs.inatClientSecret,
	}
	if not tok then return false, err end

	prefs.inatAccessToken = tok.access_token
	if tok.refresh_token then prefs.inatRefreshToken = tok.refresh_token end
	return true, nil
end

--------------------------------------------------------------------------------
-- API JWT retrieval (with caching + refresh)
--------------------------------------------------------------------------------

-- Ask www.inaturalist.org for a fresh API JWT using the current access token.
-- Returns (jwt, status). status is the HTTP code (or nil on network failure).
local function fetchApiToken()
	local headers = {
		{ field = 'Authorization', value = 'Bearer ' .. tostring(prefs.inatAccessToken) },
		{ field = 'Accept', value = 'application/json' },
	}
	local body, respHeaders = LrHttp.get(API_TOKEN_URL, headers, 30)
	local status = httpStatus(respHeaders)

	if not body then
		return nil, status
	end

	local ok, parsed = pcall(json.decode, body)
	if ok and type(parsed) == 'table' and parsed.api_token then
		return parsed.api_token, status or 200
	end

	return nil, status
end

-- Public: return a valid API JWT, refreshing transparently as needed.
-- Pass forceRefresh = true to regenerate the JWT even if the cached one looks
-- fresh (used after a mid-session 401, or the manual "Regenerate" button).
-- Returns (jwt, errorMessage).
function iNatAuth.getApiToken(forceRefresh)

	-- Legacy / manual token path: user pasted a JWT directly. Nothing to
	-- regenerate here — the pasted token is whatever it is.
	if (not iNatAuth.isAuthorized()) and prefs.inatToken and prefs.inatToken ~= '' then
		return prefs.inatToken, nil
	end

	if not iNatAuth.isAuthorized() then
		return nil, 'iNaturalist is not connected. Authorize it in the plugin settings.'
	end

	-- Use the cached JWT if it is still fresh (unless a refresh is forced).
	if not forceRefresh then
		local age = prefs.inatApiTokenFetchedAt and (os.time() - prefs.inatApiTokenFetchedAt) or math.huge
		if prefs.inatApiToken and prefs.inatApiToken ~= '' and age < API_TOKEN_MAX_AGE then
			return prefs.inatApiToken, nil
		end
	end

	-- Fetch a new JWT.
	local jwt, status = fetchApiToken()

	-- Access token rejected -> try a refresh, then one more attempt.
	if not jwt and status == 401 then
		local ok, refErr = refreshAccessToken()
		if not ok then
			return nil, refErr
		end
		jwt, status = fetchApiToken()
	end

	if not jwt then
		if status == 401 then
			return nil, 'iNaturalist authorization is no longer valid — please Authorize again.'
		end
		return nil, 'Could not obtain an iNaturalist API token'
			.. (status and (' (HTTP ' .. tostring(status) .. ')') or '') .. '.'
	end

	prefs.inatApiToken = jwt
	prefs.inatApiTokenFetchedAt = os.time()
	return jwt, nil
end

-- Public: force a brand-new API JWT (clears the cached one first). Handy for a
-- "Regenerate token" button, or to recover from a token invalidated before its
-- normal expiry. Returns (jwt, errorMessage).
function iNatAuth.regenerateApiToken()
	prefs.inatApiToken = nil
	prefs.inatApiTokenFetchedAt = nil
	return iNatAuth.getApiToken(true)
end

return iNatAuth
