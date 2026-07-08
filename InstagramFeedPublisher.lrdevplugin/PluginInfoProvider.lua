--[[----------------------------------------------------------------------------
PluginInfoProvider.lua
Settings panel shown in  File > Plug-in Manager > Instagram Feed Publisher.
Stores the GLOBAL Instagram Graph API credentials and the image-host Client ID
(shared by the publish service), and offers "Verify connection" /
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

local prefs = LrPrefs.prefsForPlugin()

--------------------------------------------------------------------------------

local function statusText()
	if prefs.igVerifiedUser and prefs.igVerifiedUser ~= '' then
		return 'Connected as @' .. prefs.igVerifiedUser
	end
	return 'Not verified'
end

-- Store a discovered account as the active one and mark it verified.
local function useAccount(properties, acct)
	prefs.igUserId = acct.igId
	prefs.igVerifiedUser = acct.igUsername
	properties.igUserId = acct.igId       -- reflect into the visible field
	properties.igStatus = statusText()
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
	local accounts, err = InstagramAPI.discoverAccounts(prefs.igAccessToken)
	if not accounts then
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

	if #accounts == 0 then
		if not silentIfNone then
			LrDialogs.message('Instagram Feed Publisher',
				'No Instagram Business account was found for this token.\n\n'
				.. 'Make sure your Instagram account is a Business/Creator account, is '
				.. 'linked to a Facebook Page you manage, and that the token carries '
				.. 'pages_show_list + instagram_basic.', 'warning')
		end
		return false
	end

	local acct = (#accounts == 1) and accounts[1] or pickAccount(accounts)
	if not acct then return false end

	useAccount(properties, acct)
	LrDialogs.message('Instagram Feed Publisher',
		'Found @' .. acct.igUsername .. ' and filled in its account id (' .. acct.igId .. ').', 'info')
	return true
end

local function doVerify(properties)
	LrTasks.startAsyncTask(function()
		local user, err = InstagramAPI.verify(prefs.igAccessToken, prefs.igUserId)
		if user then
			prefs.igVerifiedUser = user
			properties.igStatus = statusText()
			LrDialogs.message('Instagram Feed Publisher',
				'Connected successfully as @' .. user .. '.', 'info')
			return
		end

		-- Verify failed. Try to auto-discover the right account id; if that
		-- succeeds, confirm end-to-end with a second verify.
		prefs.igVerifiedUser = nil
		properties.igStatus = statusText()

		if findAccounts(properties, true) then
			local user2, err2 = InstagramAPI.verify(prefs.igAccessToken, prefs.igUserId)
			if user2 then
				prefs.igVerifiedUser = user2
				properties.igStatus = statusText()
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
		findAccounts(properties, false)
	end)
end

--------------------------------------------------------------------------------

local function sectionsForTopOfDialog(f, properties)

	local bind = LrView.bind
	properties.igStatus = statusText()

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

			f:row {
				f:static_text { title = '', width = 150 },
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
				f:push_button {
					title = 'Publishing docs…',
					action = function()
						LrHttp.openUrlInBrowser('https://developers.facebook.com/docs/instagram-api/guides/content-publishing')
					end,
				},
			},

			f:row {
				f:static_text { title = '', width = 150 },
				f:static_text {
					title = 'Requires an Instagram Business/Creator account linked to a Facebook Page,\n'
						.. 'and a long-lived token with instagram_basic + instagram_content_publish.',
					height_in_lines = 2,
					font = '<system/small>',
				},
			},
		},

		{
			title = 'Image hosting (Imgur)',

			f:row {
				f:static_text {
					title = 'Instagram fetches the photo from a public URL, so the exported JPEG is\n'
						.. 'uploaded to Imgur first (then removed). Paste a free Imgur Client ID:',
					height_in_lines = 2,
				},
			},
			f:row {
				f:static_text { title = 'Imgur Client ID:', width = 150 },
				f:edit_field {
					value = bind { key = 'imgurClientId', object = prefs },
					width_in_chars = 44,
					immediate = true,
				},
			},
			f:row {
				f:static_text { title = '', width = 150 },
				f:push_button {
					title = 'Register an Imgur app…',
					action = function()
						LrHttp.openUrlInBrowser('https://api.imgur.com/oauth2/addclient')
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
