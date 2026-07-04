--[[----------------------------------------------------------------------------
PluginInfoProvider.lua
Settings panel shown in  File > Plug-in Manager > Plant & Mushroom Tagger.
Stores API keys and default options, and drives the iNaturalist OAuth flow.
------------------------------------------------------------------------------]]

local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'

local iNatAuth = require 'iNatAuth'

local prefs = LrPrefs.prefsForPlugin()

-- Sensible defaults on first run.
if prefs.plantNetProject == nil then prefs.plantNetProject = 'all' end
if prefs.defaultOrgan == nil then prefs.defaultOrgan = 'auto' end

--------------------------------------------------------------------------------

local function statusText()
	return iNatAuth.isAuthorized() and 'iNaturalist: Connected ✓' or 'iNaturalist: Not connected'
end

-- Modal prompt asking the user to paste the authorization code from the browser.
local function promptForCode(f)
	local code
	LrFunctionContext.callWithContext('pmtagger_oauth_code', function(context)
		local props = LrBinding.makePropertyTable(context)
		props.code = ''
		local result = LrDialogs.presentModalDialog {
			title = 'iNaturalist Authorization',
			contents = f:column {
				bind_to_object = props,
				spacing = f:control_spacing(),
				width = 420,
				f:static_text {
					title = 'A browser window opened. Sign in, click "Authorize", then paste\nthe authorization code shown by iNaturalist below:',
					height_in_lines = 2,
				},
				f:edit_field { value = LrView.bind 'code', width = 400, immediate = true },
			},
			actionVerb = 'Connect',
		}
		if result == 'ok' and props.code ~= '' then
			code = props.code
		end
	end)
	return code
end

local function doAuthorize(f, properties)
	LrTasks.startAsyncTask(function()
		if not iNatAuth.hasCredentials() then
			LrDialogs.message('iNaturalist',
				'Enter the Client ID and Client Secret first.', 'warning')
			return
		end

		LrHttp.openUrlInBrowser(iNatAuth.buildAuthorizeUrl())

		local code = promptForCode(f)
		if not code then return end

		local ok, err = iNatAuth.exchangeCodeForToken(code)
		if not ok then
			LrDialogs.message('iNaturalist', 'Authorization failed:\n\n' .. tostring(err), 'critical')
			properties.inatStatus = statusText()
			return
		end

		-- Confirm end-to-end by actually fetching an API token.
		local jwt, tErr = iNatAuth.getApiToken()
		properties.inatStatus = statusText()
		if jwt then
			LrDialogs.message('iNaturalist', 'Connected successfully. The plugin will now refresh its token automatically.', 'info')
		else
			LrDialogs.message('iNaturalist',
				'Authorized, but a test token fetch failed:\n\n' .. tostring(tErr), 'warning')
		end
	end)
end

local function doSignOut(properties)
	iNatAuth.signOut()
	properties.inatStatus = statusText()
	LrDialogs.message('iNaturalist', 'Signed out.', 'info')
end

--------------------------------------------------------------------------------

local function sectionsForTopOfDialog(f, properties)

	local bind = LrView.bind
	properties.inatStatus = statusText()

	return {
		{
			title = 'Pl@ntNet',

			f:row {
				f:static_text { title = 'API key:', width = 120 },
				f:edit_field {
					value = bind { key = 'plantNetApiKey', object = prefs },
					width_in_chars = 40,
					immediate = true,
				},
			},
			f:row {
				f:static_text { title = '', width = 120 },
				f:push_button {
					title = 'Get a free Pl@ntNet key…',
					action = function()
						LrHttp.openUrlInBrowser('https://my.plantnet.org/')
					end,
				},
			},
		},

		{
			title = 'iNaturalist (OAuth — connect once, auto-refresh)',

			f:row {
				f:static_text { title = 'Status:', width = 120 },
				f:static_text {
					title = bind { key = 'inatStatus', object = properties },
					width = 300,
					font = '<system/bold>',
				},
			},

			f:spacer { height = 6 },

			f:row {
				f:static_text { title = 'Client ID:', width = 120 },
				f:edit_field {
					value = bind { key = 'inatClientId', object = prefs },
					width_in_chars = 40,
					immediate = true,
				},
			},
			f:row {
				f:static_text { title = 'Client Secret:', width = 120 },
				f:password_field {
					value = bind { key = 'inatClientSecret', object = prefs },
					width_in_chars = 40,
					immediate = true,
				},
			},

			f:row {
				f:static_text { title = '', width = 120 },
				f:push_button {
					title = 'Register an app…',
					action = function()
						LrHttp.openUrlInBrowser('https://www.inaturalist.org/oauth/applications/new')
					end,
				},
				f:push_button {
					title = 'Authorize…',
					action = function() doAuthorize(f, properties) end,
				},
				f:push_button {
					title = 'Sign out',
					action = function() doSignOut(properties) end,
				},
			},

			f:row {
				f:static_text { title = '', width = 120 },
				f:static_text {
					title = 'When registering, set the redirect URI to:  urn:ietf:wg:oauth:2.0:oob',
					font = '<system/small>',
				},
			},

			f:spacer { height = 8 },
			f:separator { fill_horizontal = 1 },
			f:spacer { height = 4 },

			f:row {
				f:static_text { title = 'Manual token:', width = 120 },
				f:edit_field {
					value = bind { key = 'inatToken', object = prefs },
					width_in_chars = 40,
					immediate = true,
				},
			},
			f:row {
				f:static_text { title = '', width = 120 },
				f:static_text {
					title = 'Advanced / fallback: paste a 24 h token from inaturalist.org/users/api_token.\nLeave blank when using OAuth above.',
					height_in_lines = 2,
					font = '<system/small>',
				},
			},
		},

		{
			title = 'Defaults',

			f:row {
				f:static_text { title = 'Pl@ntNet project:', width = 160 },
				f:popup_menu {
					value = bind { key = 'plantNetProject', object = prefs },
					items = {
						{ title = 'All floras (broadest)', value = 'all' },
						{ title = 'Western Europe', value = 'weurope' },
						{ title = 'Useful plants', value = 'useful' },
						{ title = 'World flora', value = 'k-world-flora' },
					},
				},
			},
			f:row {
				f:static_text { title = 'Default organ:', width = 160 },
				f:popup_menu {
					value = bind { key = 'defaultOrgan', object = prefs },
					items = {
						{ title = 'Auto', value = 'auto' },
						{ title = 'Leaf', value = 'leaf' },
						{ title = 'Flower', value = 'flower' },
						{ title = 'Fruit', value = 'fruit' },
						{ title = 'Bark', value = 'bark' },
					},
				},
			},
			f:row {
				f:checkbox {
					title = 'Add chosen name as a keyword',
					value = bind { key = 'optAddKeyword', object = prefs },
				},
			},
			f:row {
				f:checkbox {
					title = 'Write scientific/common name to custom metadata fields',
					value = bind { key = 'optWriteCustom', object = prefs },
				},
			},
			f:row {
				f:checkbox {
					title = 'Also write chosen name to the Caption field',
					value = bind { key = 'optWriteCaption', object = prefs },
				},
			},
		},
	}
end

return {
	sectionsForTopOfDialog = sectionsForTopOfDialog,
}
