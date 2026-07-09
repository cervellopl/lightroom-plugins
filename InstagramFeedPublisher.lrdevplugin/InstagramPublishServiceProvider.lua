--[[----------------------------------------------------------------------------
InstagramPublishServiceProvider.lua
The Publish Service definition. Registered from Info.lua as
LrExportServiceProvider with supportsIncrementalPublish = true, which turns this
export provider into a full Publish Service in the Library's Publish panel.

Workflow for the user:
  * Create the "Instagram Feed" publish service (credentials come from the
    Plug-in Manager; caption source + hashtags are set here).
  * Drag photos into its published collection and click Publish.
  * Lightroom renders each photo to JPEG using the service's export settings and
    hands the file to processRenderedPhotos below, which hosts it, posts it, and
    records the resulting media id + permalink so Lightroom knows it is published.

Each photo becomes its own single-image feed post. (Carousels don't fit the
one-item-per-rendition publish model.)
------------------------------------------------------------------------------]]

local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrErrors = import 'LrErrors'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'

local InstagramAPI = require 'InstagramAPI'
local InstagramAuth = require 'InstagramAuth'
local ImageHost = require 'ImageHost'

local prefs = LrPrefs.prefsForPlugin()

-- How long to wait for a container to finish processing before giving up.
local STATUS_POLL_ATTEMPTS = 60
local STATUS_POLL_INTERVAL = 2 -- seconds

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function connectionStatus()
	if prefs.igVerifiedUser and prefs.igVerifiedUser ~= '' then
		return 'Connected as @' .. prefs.igVerifiedUser
	end
	if prefs.igAccessToken and prefs.igAccessToken ~= '' and prefs.igUserId and prefs.igUserId ~= '' then
		return 'Credentials set — click "Verify connection"'
	end
	return 'Not connected — set up in File ▸ Plug-in Manager'
end

-- Build a caption from the chosen metadata field plus the hashtag template.
local function buildCaption(photo, settings)
	local base = ''
	local src = settings.captionSource or 'title'
	if src ~= 'none' then
		local v = photo:getFormattedMetadata(src)
		if v and v ~= '' then base = v end
	end
	local tags = settings.appendHashtags or ''
	if tags ~= '' then
		base = (base ~= '') and (base .. '\n\n' .. tags) or tags
	end
	return base
end

-- Block until a container reports FINISHED. Returns true or (false, message).
local function waitForContainer(token, containerId)
	for attempt = 1, STATUS_POLL_ATTEMPTS do
		local status, err = InstagramAPI.getContainerStatus(token, containerId)
		if not status then return false, err end

		if status == 'FINISHED' or status == 'PUBLISHED' then
			return true
		elseif status == 'ERROR' then
			return false, 'Instagram rejected the image while processing it.'
		elseif status == 'EXPIRED' then
			return false, 'The upload expired before it could be published.'
		end
		LrTasks.sleep(STATUS_POLL_INTERVAL)
	end
	return false, 'The upload did not finish in time. Try again.'
end

-- Post one already-rendered JPEG file. Returns (mediaId, permalink) or raises.
-- The hosted image auto-expires (see ImageHost), so there is nothing to clean up.
local function publishOne(token, igUserId, jpegPath, caption)
	local uploaded, uErr = ImageHost.uploadImgbb(jpegPath, prefs.imgbbApiKey)
	if not uploaded then error(uErr) end

	local containerId, cErr = InstagramAPI.createImageContainer(token, igUserId, uploaded.url, caption, false)
	if not containerId then error(cErr) end

	local ok, wErr = waitForContainer(token, containerId)
	if not ok then error(wErr) end

	local mediaId, pErr = InstagramAPI.publish(token, igUserId, containerId)
	if not mediaId then error(pErr) end

	local permalink = select(1, InstagramAPI.getPermalink(token, mediaId))
	return mediaId, permalink
end

--------------------------------------------------------------------------------
-- Provider definition
--------------------------------------------------------------------------------

local provider = {}

-- Publish-only: this appears as a Publish Service, never as a plain Export
-- target (a plain export has no published collection to record ids against).
provider.supportsIncrementalPublish = 'only'

-- Constrain the render to Instagram-friendly output and hide irrelevant panels.
provider.allowFileFormats = { 'JPEG' }
provider.allowColorSpaces = { 'sRGB' }
provider.canExportVideo = false
provider.hideSections = { 'exportLocation', 'video', 'postProcessing' }

-- Per-service settings. The LR_* keys seed Instagram-ready export defaults for a
-- newly created service; the rest are our own caption options.
provider.exportPresetFields = {
	{ key = 'captionSource', default = 'title' },
	{ key = 'appendHashtags', default = '' },

	{ key = 'LR_format', default = 'JPEG' },
	{ key = 'LR_export_colorSpace', default = 'sRGB' },
	{ key = 'LR_jpeg_quality', default = 0.9 },
	{ key = 'LR_size_doConstrain', default = true },
	{ key = 'LR_size_maxWidth', default = 1440 },
	{ key = 'LR_size_maxHeight', default = 1440 },
	{ key = 'LR_size_units', default = 'pixels' },
	{ key = 'LR_size_resolution', default = 72 },
}

--------------------------------------------------------------------------------
-- Dialog
--------------------------------------------------------------------------------

function provider.startDialog(propertyTable)
	propertyTable.igStatus = connectionStatus()
end

function provider.sectionsForTopOfDialog(f, propertyTable)
	local bind = LrView.bind

	local function doVerify()
		LrTasks.startAsyncTask(function()
			local user, err = InstagramAPI.verify(prefs.igAccessToken, prefs.igUserId)
			if user then
				prefs.igVerifiedUser = user
				propertyTable.igStatus = connectionStatus()
				LrDialogs.message('Instagram Feed Publisher', 'Connected as @' .. user .. '.', 'info')
			else
				propertyTable.igStatus = connectionStatus()
				LrDialogs.message('Instagram Feed Publisher',
					'Could not verify the connection:\n\n' .. tostring(err)
					.. '\n\nManage your token and account id in File ▸ Plug-in Manager.', 'warning')
			end
		end)
	end

	return {
		{
			title = 'Instagram connection',

			f:row {
				f:static_text { title = 'Status:', width = 110 },
				f:static_text {
					title = bind { key = 'igStatus', object = propertyTable },
					width = 340,
					font = '<system/bold>',
				},
			},
			f:row {
				f:static_text { title = '', width = 110 },
				f:push_button { title = 'Verify connection', action = doVerify },
			},
			f:row {
				f:static_text { title = '', width = 110 },
				f:static_text {
					title = 'The access token, Instagram account id and ImgBB API key are managed\n'
						.. 'in File ▸ Plug-in Manager ▸ Instagram Feed Publisher.',
					height_in_lines = 2,
					font = '<system/small>',
				},
			},
		},
		{
			title = 'Caption',

			f:row {
				f:static_text { title = 'Caption from:', width = 110 },
				f:popup_menu {
					value = bind 'captionSource',
					items = {
						{ title = 'Nothing (hashtags only)', value = 'none' },
						{ title = 'Title', value = 'title' },
						{ title = 'Caption', value = 'caption' },
						{ title = 'Headline', value = 'headline' },
					},
					width = 200,
				},
			},
			f:row {
				f:static_text { title = 'Append hashtags:', width = 110 },
				f:edit_field {
					value = bind 'appendHashtags',
					width_in_chars = 40,
					immediate = true,
				},
			},
			f:row {
				f:static_text { title = '', width = 110 },
				f:static_text {
					title = 'Each photo is posted as its own feed image. Caption is taken from the\n'
						.. 'field above (per photo) plus these hashtags. Max 2,200 chars / 30 tags.',
					height_in_lines = 2,
					font = '<system/small>',
				},
			},
		},
	}
end

--------------------------------------------------------------------------------
-- Publish behaviour
--------------------------------------------------------------------------------

-- The default published collection and how collections behave for this service.
function provider.getCollectionBehaviorInfo(publishSettings)
	return {
		defaultCollectionName = 'Instagram Feed',
		defaultCollectionCanBeDeleted = false,
		canAddCollection = true,
		maxCollectionSetDepth = 0, -- flat: no collection sets
	}
end

-- Editing any of these marks a published photo as "modified" (re-publishable).
function provider.metadataThatTriggersRepublish(publishSettings)
	return {
		default = false,
		title = true,
		caption = true,
		keywords = true,
	}
end

-- Instagram's Graph API has no endpoint to delete a published feed post, so when
-- the user removes a photo from the collection we can only forget it locally.
function provider.deletePhotosFromPublishedCollection(publishSettings, arrayOfPhotoIds, deletedCallback)
	for _, photoId in ipairs(arrayOfPhotoIds) do
		deletedCallback(photoId)
	end
end

-- Main entry point: called for every photo that needs (re)publishing.
function provider.processRenderedPhotos(functionContext, exportContext)
	local exportSettings = exportContext.propertyTable
	local exportSession = exportContext.exportSession

	-- Fail fast (and clearly) if the plugin isn't configured yet.
	-- ensureFreshToken refreshes the long-lived token when it is nearing expiry.
	local token = InstagramAuth.ensureFreshToken()
	local igUserId = prefs.igUserId
	if not (token and token ~= '' and igUserId and igUserId ~= '') then
		LrErrors.throwUserError(
			'Instagram is not connected. Open File ▸ Plug-in Manager ▸ Instagram Feed '
			.. 'Publisher and set your access token and Instagram account id.')
	end
	if not (prefs.imgbbApiKey and prefs.imgbbApiKey ~= '') then
		LrErrors.throwUserError(
			'No ImgBB API key configured (needed to host the image for Instagram). '
			.. 'Set it in the Plug-in Manager.')
	end

	local nPhotos = exportSession:countRenditions()
	exportContext:configureProgress {
		title = (nPhotos > 1)
			and string.format('Publishing %d photos to Instagram', nPhotos)
			or 'Publishing 1 photo to Instagram',
	}

	for i, rendition in exportContext:renditions { stopIfCanceled = true } do
		local success, pathOrMessage = rendition:waitForRender()
		if success then
			local caption = buildCaption(rendition.photo, exportSettings)

			-- pcallWithContext, NOT plain pcall: the HTTP/sleep calls below yield,
			-- and Lua 5.1 cannot yield across a C-level pcall boundary. This keeps
			-- one photo's failure from aborting the whole publish batch.
			local ok, mediaIdOrErr, permalink =
				LrFunctionContext.pcallWithContext('igpublish_one', function()
					return publishOne(token, igUserId, pathOrMessage, caption)
				end)

			if ok then
				rendition:recordPublishedPhotoId(mediaIdOrErr)
				if permalink then rendition:recordPublishedPhotoUrl(permalink) end
			else
				rendition:uploadFailed(tostring(mediaIdOrErr))
			end
		end
		-- On render failure Lightroom has already recorded the message.
	end
end

return provider
