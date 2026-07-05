--[[----------------------------------------------------------------------------
PublishToInstagram.lua
Main workflow, launched from  Library > Plug-in Extras >
"Publish to Instagram Feed…".

  1. Take the selected photo(s) — one becomes a single feed post, several become
     a carousel (Instagram allows up to 10).
  2. Let the user review / edit the caption.
  3. For each photo: render a JPEG, upload it to the image host to obtain a
     public URL, and create an Instagram media container.
  4. Wait for the container(s) to finish processing, then publish.
  5. Record the resulting permalink in the photo metadata.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'
local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrProgressScope = import 'LrProgressScope'

local InstagramAPI = require 'InstagramAPI'
local ImageHost = require 'ImageHost'

local prefs = LrPrefs.prefsForPlugin()

-- Instagram's hard limit for images in one carousel.
local MAX_CAROUSEL = 10

-- How long to wait for a container to finish processing before giving up.
local STATUS_POLL_ATTEMPTS = 60
local STATUS_POLL_INTERVAL = 2 -- seconds

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Render the photo to a JPEG temp file (Instagram/Imgur both need a real file).
-- Returns (tmpPath, nil) or (nil, errorMessage).
local function renderJpeg(photo, size)
	local data, err, done = nil, nil, false
	photo:requestJpegThumbnail(size, size, function(jpegData, errorMsg)
		data, err, done = jpegData, errorMsg, true
	end)

	local waited = 0
	while not done and waited < 30 do
		LrTasks.sleep(0.1)
		waited = waited + 0.1
	end

	if not data then
		return nil, (err or 'Could not render a JPEG for this photo.')
	end

	local tmpPath = LrPathUtils.child(
		LrPathUtils.getStandardFilePath('temp'),
		'igpublish_' .. tostring(os.time()) .. '_' .. tostring(math.random(1000, 9999)) .. '.jpg')

	local fh, ioErr = io.open(tmpPath, 'wb')
	if not fh then
		return nil, 'Could not write a temporary file: ' .. tostring(ioErr)
	end
	fh:write(data)
	fh:close()

	return tmpPath, nil
end

-- Build the caption offered in the dialog from the photo's metadata + defaults.
local function buildDefaultCaption(photo)
	local base = ''
	if prefs.useCaptionFromMetadata then
		for _, field in ipairs({ 'title', 'caption', 'headline' }) do
			local v = photo:getFormattedMetadata(field)
			if v and v ~= '' then base = v break end
		end
	end

	local tags = prefs.defaultHashtags or ''
	if tags ~= '' then
		if base ~= '' then base = base .. '\n\n' .. tags else base = tags end
	end
	return base
end

-- Render one photo and push it to the image host.
-- Returns (imageUrl, tmpPath, deleteHash) or raises via error() on failure.
local function stageImage(photo)
	local tmpPath, rErr = renderJpeg(photo, prefs.jpegLongEdge or 1440)
	if not tmpPath then error(rErr) end

	local uploaded, uErr = ImageHost.uploadImgur(tmpPath, prefs.imgurClientId)
	if not uploaded then
		pcall(function() LrFileUtils.delete(tmpPath) end)
		error(uErr)
	end
	return uploaded.url, tmpPath, uploaded.deleteHash
end

-- Block until a container reports FINISHED. Returns true or (false, message).
local function waitForContainer(token, containerId, progress, label)
	for attempt = 1, STATUS_POLL_ATTEMPTS do
		local status, err = InstagramAPI.getContainerStatus(token, containerId)
		if not status then return false, err end

		if status == 'FINISHED' or status == 'PUBLISHED' then
			return true
		elseif status == 'ERROR' then
			return false, (label or 'The upload') .. ' failed while Instagram processed it.'
		elseif status == 'EXPIRED' then
			return false, (label or 'The upload') .. ' expired before it could be published.'
		end

		if progress then
			progress:setCaption(string.format('%s — processing… (%ds)',
				label or 'Uploading', attempt * STATUS_POLL_INTERVAL))
		end
		LrTasks.sleep(STATUS_POLL_INTERVAL)
	end
	return false, (label or 'The upload') .. ' did not finish in time. Try again.'
end

--------------------------------------------------------------------------------
-- Review dialog
--------------------------------------------------------------------------------

local function showDialog(photos)
	local result = nil
	local isCarousel = #photos > 1

	LrFunctionContext.callWithContext('igpublish_review', function(context)
		local f = LrView.osFactory()
		local props = LrBinding.makePropertyTable(context)

		props.caption = buildDefaultCaption(photos[1])
		props.writePermalink = prefs.optWritePermalink

		local heading = isCarousel
			and string.format('Publish a carousel of %d photos to Instagram:', #photos)
			or 'Publish this photo to your Instagram feed:'

		local bind = LrView.bind

		local contents = f:column {
			bind_to_object = props,
			spacing = f:control_spacing(),
			width = 500,

			f:static_text { title = heading, font = '<system/bold>' },

			f:spacer { height = 4 },

			f:static_text { title = 'Caption:' },
			f:edit_field {
				value = bind 'caption',
				width = 480,
				height_in_lines = 6,
				immediate = true,
			},
			f:static_text {
				title = 'Up to 2,200 characters and 30 hashtags.',
				font = '<system/small>',
			},

			f:spacer { height = 6 },
			f:separator { fill_horizontal = 1 },
			f:spacer { height = 4 },

			f:checkbox {
				title = 'Record the Instagram permalink in the photo metadata',
				value = bind 'writePermalink',
			},
		}

		local button = LrDialogs.presentModalDialog {
			title = 'Publish to Instagram Feed',
			contents = contents,
			actionVerb = 'Publish',
		}

		if button == 'ok' then
			result = {
				caption = props.caption or '',
				writePermalink = props.writePermalink,
			}
			prefs.optWritePermalink = props.writePermalink
		end
	end)

	return result
end

--------------------------------------------------------------------------------
-- Publish
--------------------------------------------------------------------------------

-- Publishes the photos and returns (mediaId, tmpPaths, deleteHashes) or raises.
local function doPublish(photos, caption, progress)
	local token = prefs.igAccessToken
	local igUserId = prefs.igUserId
	local tmpPaths, deleteHashes = {}, {}

	local function remember(tmpPath, deleteHash)
		table.insert(tmpPaths, tmpPath)
		if deleteHash then table.insert(deleteHashes, deleteHash) end
	end

	local mediaId

	if #photos == 1 then
		-- Single feed post.
		progress:setCaption('Rendering and uploading the photo…')
		local url, tmpPath, deleteHash = stageImage(photos[1])
		remember(tmpPath, deleteHash)

		progress:setCaption('Creating the Instagram post…')
		local containerId, cErr = InstagramAPI.createImageContainer(token, igUserId, url, caption, false)
		if not containerId then error(cErr) end

		local ok, wErr = waitForContainer(token, containerId, progress, 'Photo')
		if not ok then error(wErr) end

		progress:setCaption('Publishing…')
		local id, pErr = InstagramAPI.publish(token, igUserId, containerId)
		if not id then error(pErr) end
		mediaId = id
	else
		-- Carousel.
		local childIds = {}
		for i, photo in ipairs(photos) do
			progress:setCaption(string.format('Rendering and uploading photo %d of %d…', i, #photos))
			local url, tmpPath, deleteHash = stageImage(photo)
			remember(tmpPath, deleteHash)

			local childId, cErr = InstagramAPI.createImageContainer(token, igUserId, url, nil, true)
			if not childId then error(cErr) end

			local ok, wErr = waitForContainer(token, childId, progress,
				string.format('Photo %d', i))
			if not ok then error(wErr) end

			table.insert(childIds, childId)
		end

		progress:setCaption('Assembling the carousel…')
		local parentId, pcErr = InstagramAPI.createCarouselContainer(token, igUserId, childIds, caption)
		if not parentId then error(pcErr) end

		local ok, wErr = waitForContainer(token, parentId, progress, 'Carousel')
		if not ok then error(wErr) end

		progress:setCaption('Publishing…')
		local id, pErr = InstagramAPI.publish(token, igUserId, parentId)
		if not id then error(pErr) end
		mediaId = id
	end

	return mediaId, tmpPaths, deleteHashes
end

-- Write the media id / permalink / timestamp onto every published photo.
local function writeResultMetadata(catalog, photos, mediaId, permalink)
	catalog:withWriteAccessDo('Record Instagram publish', function()
		local stamp = os.date('%Y-%m-%d %H:%M:%S')
		for _, photo in ipairs(photos) do
			photo:setPropertyForPlugin(_PLUGIN, 'instagramMediaId', mediaId)
			if permalink then
				photo:setPropertyForPlugin(_PLUGIN, 'instagramPermalink', permalink)
			end
			photo:setPropertyForPlugin(_PLUGIN, 'instagramPublishedAt', stamp)
		end
	end, { timeout = 15 })
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

LrTasks.startAsyncTask(function()
	LrFunctionContext.callWithContext('igpublish_main', function(context)

		local catalog = LrApplication.activeCatalog()
		local photos = catalog:getTargetPhotos()
		if not photos or #photos == 0 then
			local one = catalog:getTargetPhoto()
			photos = one and { one } or {}
		end

		if #photos == 0 then
			LrDialogs.message('Instagram Feed Publisher',
				'Select one or more photos in the Library, then run the command again.', 'info')
			return
		end

		-- Configuration checks.
		local missing = {}
		if not (prefs.igAccessToken and prefs.igAccessToken ~= '') then
			table.insert(missing, 'the Instagram access token')
		end
		if not (prefs.igUserId and prefs.igUserId ~= '') then
			table.insert(missing, 'the Instagram account id')
		end
		if not (prefs.imgurClientId and prefs.imgurClientId ~= '') then
			table.insert(missing, 'the Imgur Client ID (used to host the image)')
		end
		if #missing > 0 then
			LrDialogs.message('Instagram Feed Publisher',
				'Before publishing, open File > Plug-in Manager > Instagram Feed Publisher and set '
				.. table.concat(missing, ', ') .. '.', 'warning')
			return
		end

		-- Enforce the carousel size limit up front.
		if #photos > MAX_CAROUSEL then
			local go = LrDialogs.confirm('Instagram Feed Publisher',
				string.format('You selected %d photos, but an Instagram carousel holds at most %d. '
					.. 'Publish the first %d?', #photos, MAX_CAROUSEL, MAX_CAROUSEL),
				'Publish first ' .. MAX_CAROUSEL, 'Cancel')
			if go ~= 'ok' then return end
			local trimmed = {}
			for i = 1, MAX_CAROUSEL do trimmed[i] = photos[i] end
			photos = trimmed
		end

		local choice = showDialog(photos)
		if not choice then return end -- user cancelled

		local progress = LrProgressScope { title = 'Publishing to Instagram…' }
		progress:setCancelable(false)

		-- NOTE: pcallWithContext, NOT plain pcall — everything below yields
		-- (HTTP, sleep, catalog write) and Lua 5.1 cannot yield across a C-level
		-- pcall boundary.
		local tmpPaths, deleteHashes = {}, {}
		local ok, resultOrErr = LrFunctionContext.pcallWithContext('igpublish_run', function()
			local mediaId, paths, hashes = doPublish(photos, choice.caption, progress)
			tmpPaths, deleteHashes = paths, hashes

			-- Permalink is best-effort; a failure here must not fail the publish.
			local permalink = select(1, InstagramAPI.getPermalink(prefs.igAccessToken, mediaId))

			if choice.writePermalink then
				writeResultMetadata(catalog, photos, mediaId, permalink)
			end

			return { mediaId = mediaId, permalink = permalink }
		end)

		progress:done()

		-- Clean up temp files and the temporary Imgur uploads.
		for _, p in ipairs(tmpPaths) do
			if p and LrFileUtils.exists(p) then
				pcall(function() LrFileUtils.delete(p) end)
			end
		end
		for _, h in ipairs(deleteHashes) do
			ImageHost.deleteImgur(h, prefs.imgurClientId)
		end

		if not ok then
			LrDialogs.message('Instagram Feed Publisher',
				'Publishing failed:\n\n' .. tostring(resultOrErr), 'critical')
			return
		end

		local who = (prefs.igVerifiedUser and prefs.igVerifiedUser ~= '')
			and ('@' .. prefs.igVerifiedUser) or 'your Instagram feed'
		if resultOrErr.permalink then
			local r = LrDialogs.confirm('Instagram Feed Publisher',
				'Published to ' .. who .. '.', 'Open post', 'Close')
			if r == 'ok' then LrHttp.openUrlInBrowser(resultOrErr.permalink) end
		else
			LrDialogs.showBezel('Published to ' .. who)
		end
	end)
end)
