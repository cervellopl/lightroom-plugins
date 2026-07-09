--[[----------------------------------------------------------------------------
PluginInfoProvider.lua
Settings panel shown in  File > Plug-in Manager > Instagram Feed Publisher.
Stores the GLOBAL Instagram Graph API credentials (access token, account id,
App ID/Secret) and the image-host key, shared by the publish service. Offers
"Get long-lived token" (auto-refreshing), "Verify connection" and
"Find my account id". Per-service options (caption, hashtags, image size) live
in the "Instagram Feed" publish service's own Edit Settings dialog.
------------------------------------------------------------------------------]]

local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'

local InstagramAPI = require 'InstagramAPI'
local InstagramAuth = require 'InstagramAuth'

local prefs = LrPrefs.prefsForPlugin()

--------------------------------------------------------------------------------

local function statusText()
	if prefs.igVerifiedUser and prefs.igVerifiedUser ~= '' then
		return 'Connected as @' .. prefs.igVerifiedUser
	end
	return 'Not verified'
end

-- Push the current connection + token status into the bound dialog fields.
local function refreshStatus(properties)
	properties.igStatus = statusText()
	properties.tokenStatus = InstagramAuth.tokenStatus()
end

-- Store a discovered account as the active one and mark it verified.
local function useAccount(properties, acct)
	prefs.igUserId = acct.igId
	prefs.igVerifiedUser = acct.igUsername
	properties.igUserId = acct.igId       -- reflect into the visible field
	refreshStatus(properties)
end

-- Let the user pick when a token exposes more than one Instagram account.
-- Returns the chosen account table, or nil if cancelled.
local function pickAccount(accounts)
	local chosen = nil
	LrFunctionContext.callWithContext('igpublish_pick_account', function(context)
		local f = LrView.osFactory()
		local props = LrBinding.makePropertyTable(context)
		props.selected = 1

		local items = {}
		for i, a in ipairs(accounts) do
			items[i] = {
				title = string.format('@%s   (Page: %s)  —  id %s',
					a.igUsername, a.pageName, a.igId),
				value = i,
			}
		end

		local button = LrDialogs.presentModalDialog {
			title = 'Choose an Instagram account',
			contents = f:column {
				bind_to_object = props,
				spacing = f:control_spacing(),
				width = 460,
				f:static_text { title = 'This token can post to more than one account:' },
				f:popup_menu { value = LrView.bind 'selected', items = items, width = 440 },
			},
			actionVerb = 'Use this account',
		}
		if button == 'ok' then chosen = accounts[props.selected] end
	end)
	return chosen
end

-- Resolve the correct IG account id from the token via the user's Pages.
-- Returns true if an account was applied. `silentIfNone` suppresses the
-- "nothing found" dialog (used as a fallback after a failed verify).
local function findAccounts(properties, silentIfNone)
	local info, err = InstagramAPI.discoverAccounts(prefs.igAccessToken)
	if not info then
		-- Only nudge about permissions when it isn't really a dead-token problem.
		local e = tostring(err)
		local hint = ''
		if not (e:find('expired') or e:find('invalid')) then
			hint = '\n\nThe token also needs the pages_show_list permission for this.'
		end
		LrDialogs.message('Instagram Feed Publisher',
			'Could not look up your accounts:\n\n' .. e .. hint, 'warning')
		return false
	end

	if #info.usable == 0 then
		if not silentIfNone then
			local msg
			if #info.pageNames == 0 then
				-- No Pages at all -> wrong token type or missing permission.
				msg = 'No Facebook Pages are visible to this token.\n\n'
					.. 'Either the token is missing the pages_show_list permission, or it '
					.. 'was created with "Instagram API with Instagram Login". This plugin '
					.. 'uses the Facebook Login flow, which needs your Instagram account '
					.. 'linked to a Facebook Page you manage.'
			elseif #info.connectedOnly > 0 then
				-- IG is connected to a Page but not a Business/Creator account.
				local parts = {}
				for _, c in ipairs(info.connectedOnly) do
					local who = (c.igUsername ~= '' and ('@' .. c.igUsername)) or 'An Instagram account'
					table.insert(parts, '  ' .. who .. '  (Page: ' .. c.pageName .. ')')
				end
				msg = 'An Instagram account is connected, but it is not a Business/Creator '
					.. 'account, so it cannot publish via the API:\n\n'
					.. table.concat(parts, '\n') .. '\n\n'
					.. 'In the Instagram app: Settings ▸ Account type and tools ▸ switch to '
					.. 'Professional (Business or Creator), then reconnect it to the Page.'
			else
				-- Pages exist, but none links an Instagram account at all.
				msg = 'Found these Facebook Pages, but none has an Instagram account linked:\n\n  '
					.. table.concat(info.pageNames, '\n  ') .. '\n\n'
					.. 'Link your Instagram (Business/Creator) account to one of these Pages '
					.. '(Page ▸ Settings ▸ Linked accounts / Instagram), then try again.'
			end
			LrDialogs.message('Instagram Feed Publisher', msg, 'warning')
		end
		return false
	end

	local acct = (#info.usable == 1) and info.usable[1] or pickAccount(info.usable)
	if not acct then return false end

	useAccount(properties, acct)
	LrDialogs.message('Instagram Feed Publisher',
		'Found @' .. acct.igUsername .. ' and filled in its account id (' .. acct.igId .. ').', 'info')
	return true
end

local function doVerify(properties)
	LrTasks.startAsyncTask(function()
		InstagramAuth.ensureFreshToken() -- refresh a stale long-lived token first
		local user, err = InstagramAPI.verify(prefs.igAccessToken, prefs.igUserId)
		if user then
			prefs.igVerifiedUser = user
			refreshStatus(properties)
			LrDialogs.message('Instagram Feed Publisher',
				'Connected successfully as @' .. user .. '.', 'info')
			return
		end

		-- Verify failed. Try to auto-discover the right account id; if that
		-- succeeds, confirm end-to-end with a second verify.
		prefs.igVerifiedUser = nil
		refreshStatus(properties)

		if findAccounts(properties, true) then
			local user2, err2 = InstagramAPI.verify(prefs.igAccessToken, prefs.igUserId)
			if user2 then
				prefs.igVerifiedUser = user2
				refreshStatus(properties)
				LrDialogs.message('Instagram Feed Publisher',
					'Connected successfully as @' .. user2 .. '.', 'info')
			else
				LrDialogs.message('Instagram Feed Publisher',
					'Filled in the account id, but verification still failed:\n\n'
					.. tostring(err2), 'critical')
			end
			return
		end

		LrDialogs.message('Instagram Feed Publisher',
			'Could not verify the connection:\n\n' .. tostring(err), 'critical')
	end)
end

local function doFindAccounts(properties)
	LrTasks.startAsyncTask(function()
		InstagramAuth.ensureFreshToken()
		findAccounts(properties, false)
		refreshStatus(properties)
	end)
end

-- Turn the pasted (short-lived) token into a long-lived, auto-refreshing one.
local function doGetLongLived(properties)
	LrTasks.startAsyncTask(function()
		local ok, err = InstagramAuth.makeLongLived()
		refreshStatus(properties)
		if ok then
			LrDialogs.message('Instagram Feed Publisher',
				'Got a long-lived token. The plugin will now refresh it automatically '
				.. 'before it expires, so it stays connected.\n\n'
				.. InstagramAuth.tokenStatus() .. '.', 'info')
		else
			LrDialogs.message('Instagram Feed Publisher',
				'Could not get a long-lived token:\n\n' .. tostring(err), 'warning')
		end
	end)
end

--------------------------------------------------------------------------------

local function sectionsForTopOfDialog(f, properties)

	local bind = LrView.bind
	refreshStatus(properties)

	return {
		{
			title = 'Instagram Graph API',

			f:row {
				f:static_text { title = 'Status:', width = 150 },
				f:static_text {
					title = bind { key = 'igStatus', object = properties },
					width = 320,
					font = '<system/bold>',
				},
			},
			f:row {
				f:static_text { title = 'Token:', width = 150 },
				f:static_text {
					title = bind { key = 'tokenStatus', object = properties },
					width = 320,
				},
			},

			f:spacer { height = 6 },

			f:row {
				f:static_text { title = 'Access token:', width = 150 },
				f:password_field {
					value = bind { key = 'igAccessToken', object = prefs },
					width_in_chars = 44,
					immediate = true,
				},
			},
			f:row {
				f:static_text { title = 'Instagram account id:', width = 150 },
				f:edit_field {
					value = bind { key = 'igUserId', object = prefs },
					width_in_chars = 44,
					immediate = true,
				},
			},

			f:spacer { height = 4 },

			-- App ID + Secret are needed to refresh the token so it never expires.
			f:row {
				f:static_text { title = 'App ID:', width = 150 },
				f:edit_field {
					value = bind { key = 'igAppId', object = prefs },
					width_in_chars = 44,
					immediate = true,
				},
			},
			f:row {
				f:static_text { title = 'App Secret:', width = 150 },
				f:password_field {
					value = bind { key = 'igAppSecret', object = prefs },
					width_in_chars = 44,
					immediate = true,
				},
			},

			f:row {
				f:static_text { title = '', width = 150 },
				f:push_button {
					title = 'Get long-lived token',
					action = function() doGetLongLived(properties) end,
				},
				f:push_button {
					title = 'Verify connection',
					action = function() doVerify(properties) end,
				},
				f:push_button {
					title = 'Find my account id',
					action = function() doFindAccounts(properties) end,
				},
				f:push_button {
					title = 'Graph API Explorer…',
					action = function()
						LrHttp.openUrlInBrowser('https://developers.facebook.com/tools/explorer/')
					end,
				},
			},

			f:row {
				f:static_text { title = '', width = 150 },
				f:static_text {
					title = 'Requires an Instagram Business/Creator account linked to a Facebook Page,\n'
						.. 'and a token with instagram_basic + instagram_content_publish + pages_show_list.\n'
						.. 'Add the App ID/Secret (Meta app ▸ Settings ▸ Basic) and click "Get long-lived\n'
						.. 'token" — the plugin then auto-refreshes it so it never expires.',
					height_in_lines = 4,
					font = '<system/small>',
				},
			},
		},

		{
			title = 'Image hosting (ImgBB)',

			f:row {
				f:static_text {
					title = 'Instagram fetches the photo from a public URL, so the rendered JPEG is\n'
						.. 'uploaded to ImgBB first (and auto-deleted minutes later). Paste a free\n'
						.. 'ImgBB API key:',
					height_in_lines = 3,
				},
			},
			f:row {
				f:static_text { title = 'ImgBB API key:', width = 150 },
				f:edit_field {
					value = bind { key = 'imgbbApiKey', object = prefs },
					width_in_chars = 44,
					immediate = true,
				},
			},
			f:row {
				f:static_text { title = '', width = 150 },
				f:push_button {
					title = 'Get a free ImgBB key…',
					action = function()
						LrHttp.openUrlInBrowser('https://api.imgbb.com/')
					end,
				},
			},
		},

		{
			title = 'Publishing',

			f:row {
				f:static_text {
					title = 'Photos are posted from the "Instagram Feed" publish service in the\n'
						.. 'Library\'s Publish Services panel. Caption source, hashtags and image\n'
						.. 'size are configured there, in the service\'s Edit Settings dialog.',
					height_in_lines = 3,
					font = '<system/small>',
				},
			},
		},
	}
end

return {
	sectionsForTopOfDialog = sectionsForTopOfDialog,
}
