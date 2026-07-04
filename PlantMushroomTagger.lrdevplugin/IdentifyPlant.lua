--[[----------------------------------------------------------------------------
IdentifyPlant.lua
Main workflow, launched from  Library > Plug-in Extras >
"Identify Plant / Mushroom…".

  1. Grab a JPEG of the currently selected photo.
  2. Query Pl@ntNet (plants) and Google Cloud Vision (plants + fungi) in the
     background.
  3. Present a dialog listing the merged, score-ranked name suggestions.
  4. Write the chosen name to keywords / custom metadata / caption.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'
local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrProgressScope = import 'LrProgressScope'

local PlantNetAPI = require 'PlantNetAPI'
local iNaturalistAPI = require 'iNaturalistAPI'
local iNatAuth = require 'iNatAuth'

local prefs = LrPrefs.prefsForPlugin()

-- First-run defaults for the write options.
if prefs.optAddKeyword == nil then prefs.optAddKeyword = true end
if prefs.optWriteCustom == nil then prefs.optWriteCustom = true end
if prefs.optWriteCaption == nil then prefs.optWriteCaption = false end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Render the photo to JPEG bytes (from the Lightroom preview) and also drop a
-- temp file to disk (Pl@ntNet's multipart upload needs a file path).
local function getJpeg(photo, size)
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
		return nil, nil, (err or 'Could not render a JPEG preview for this photo.')
	end

	local tmpPath = LrPathUtils.child(
		LrPathUtils.getStandardFilePath('temp'),
		'pmtagger_' .. tostring(os.time()) .. '_' .. tostring(math.random(1000, 9999)) .. '.jpg')

	local fh, ioErr = io.open(tmpPath, 'wb')
	if not fh then
		return data, nil, nil -- still return bytes; Google can run without a file
	end
	fh:write(data)
	fh:close()

	return data, tmpPath, nil
end

local function displayName(s)
	if s.scientificName and s.scientificName ~= '' then
		if s.commonName and s.commonName ~= '' then
			return s.scientificName .. ' — ' .. s.commonName
		end
		return s.scientificName
	end
	return s.commonName or '(unknown)'
end

-- Preferred single string to write as the tag.
local function primaryName(s)
	if s.scientificName and s.scientificName ~= '' then return s.scientificName end
	return s.commonName or ''
end

-- Merge the two suggestion lists, dedupe by name, sort by score descending.
local function mergeSuggestions(a, b)
	local all = {}
	for _, s in ipairs(a or {}) do table.insert(all, s) end
	for _, s in ipairs(b or {}) do table.insert(all, s) end

	local seen, merged = {}, {}
	for _, s in ipairs(all) do
		local key = (primaryName(s)):lower()
		if key ~= '' then
			if seen[key] then
				local existing = merged[seen[key]]
				if s.score > existing.score then existing.score = s.score end
				if existing.source ~= s.source and not existing.source:find(s.source, 1, true) then
					existing.source = existing.source .. '+' .. s.source
				end
				-- Fill in a scientific name if one source has it and the other doesn't.
				if (existing.scientificName == '' ) and s.scientificName ~= '' then
					existing.scientificName = s.scientificName
				end
				if (existing.commonName == '') and s.commonName ~= '' then
					existing.commonName = s.commonName
				end
			else
				local copy = {
					scientificName = s.scientificName or '',
					commonName = s.commonName or '',
					family = s.family or '',
					score = s.score or 0,
					source = s.source or '',
				}
				table.insert(merged, copy)
				seen[key] = #merged
			end
		end
	end

	table.sort(merged, function(x, y) return x.score > y.score end)
	return merged
end

--------------------------------------------------------------------------------
-- Picker dialog
--------------------------------------------------------------------------------

local function showPicker(suggestions)
	local chosen = nil

	LrFunctionContext.callWithContext('pmtagger_pick', function(context)
		local f = LrView.osFactory()
		local props = LrBinding.makePropertyTable(context)

		props.selected = 1
		props.finalName = primaryName(suggestions[1])
		props.optAddKeyword = prefs.optAddKeyword
		props.optWriteCustom = prefs.optWriteCustom
		props.optWriteCaption = prefs.optWriteCaption

		-- When the popup selection changes, refresh the editable name field.
		props:addObserver('selected', function()
			local s = suggestions[props.selected]
			if s then props.finalName = primaryName(s) end
		end)

		local items = {}
		for i, s in ipairs(suggestions) do
			table.insert(items, {
				title = string.format('%s   [%s · %d%%]',
					displayName(s), s.source, math.floor((s.score or 0) * 100 + 0.5)),
				value = i,
			})
		end

		local bind = LrView.bind

		local contents = f:column {
			bind_to_object = props,
			spacing = f:control_spacing(),
			width = 460,

			f:static_text {
				title = 'Suggested names (best match first):',
				font = '<system/bold>',
			},
			f:popup_menu {
				value = bind 'selected',
				items = items,
				width = 440,
			},

			f:spacer { height = 6 },

			f:row {
				f:static_text { title = 'Name to write:', width = 100 },
				f:edit_field {
					value = bind 'finalName',
					width = 330,
					immediate = true,
				},
			},

			f:spacer { height = 8 },
			f:separator { fill_horizontal = 1 },
			f:spacer { height = 4 },

			f:static_text { title = 'Write to:', font = '<system/bold>' },
			f:checkbox { title = 'Keyword', value = bind 'optAddKeyword' },
			f:checkbox { title = 'Custom metadata fields (Scientific / Common name)', value = bind 'optWriteCustom' },
			f:checkbox { title = 'Caption', value = bind 'optWriteCaption' },
		}

		local result = LrDialogs.presentModalDialog {
			title = 'Identify Plant / Mushroom',
			contents = contents,
			actionVerb = 'Apply Tag',
		}

		if result == 'ok' then
			local s = suggestions[props.selected]
			chosen = {
				name = (props.finalName ~= '' and props.finalName) or primaryName(s),
				scientificName = s.scientificName or '',
				commonName = s.commonName or '',
				source = s.source or '',
				score = s.score or 0,
				addKeyword = props.optAddKeyword,
				writeCustom = props.optWriteCustom,
				writeCaption = props.optWriteCaption,
			}
			-- Persist the write-target choices as the new defaults.
			prefs.optAddKeyword = props.optAddKeyword
			prefs.optWriteCustom = props.optWriteCustom
			prefs.optWriteCaption = props.optWriteCaption
		end
	end)

	return chosen
end

--------------------------------------------------------------------------------
-- Write metadata
--------------------------------------------------------------------------------

local function applyTag(catalog, photo, chosen)
	catalog:withWriteAccessDo('Identify Plant / Mushroom', function()

		if chosen.addKeyword and chosen.name ~= '' then
			local kw = catalog:createKeyword(chosen.name, {}, true, nil, true)
			if kw then photo:addKeyword(kw) end
		end

		if chosen.writeCustom then
			if chosen.scientificName ~= '' then
				photo:setPropertyForPlugin(_PLUGIN, 'scientificName', chosen.scientificName)
			end
			if chosen.commonName ~= '' then
				photo:setPropertyForPlugin(_PLUGIN, 'commonName', chosen.commonName)
			end
			photo:setPropertyForPlugin(_PLUGIN, 'idSource', chosen.source)
			photo:setPropertyForPlugin(_PLUGIN, 'idConfidence',
				string.format('%d%%', math.floor((chosen.score or 0) * 100 + 0.5)))
		end

		if chosen.writeCaption and chosen.name ~= '' then
			photo:setRawMetadata('caption', chosen.name)
		end

	end, { timeout = 15 })
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

LrTasks.startAsyncTask(function()
	LrFunctionContext.callWithContext('pmtagger_main', function(context)

		local catalog = LrApplication.activeCatalog()
		local photo = catalog:getTargetPhoto()

		if not photo then
			LrDialogs.message('Plant & Mushroom Tagger',
				'Select a single photo in the Library, then run the command again.', 'info')
			return
		end

		local plantNetReady = prefs.plantNetApiKey and prefs.plantNetApiKey ~= ''
		local inatReady = iNatAuth.isConfigured()

		if not plantNetReady and not inatReady then
			LrDialogs.message('Plant & Mushroom Tagger',
				'No identification service is configured.\n\nOpen File > Plug-in Manager > Plant & Mushroom Tagger and add a Pl@ntNet API key and/or connect iNaturalist (OAuth).',
				'warning')
			return
		end

		local progress = LrProgressScope { title = 'Identifying plant / mushroom…' }
		progress:setCancelable(false)

		-- NOTE: use pcallWithContext, NOT plain pcall. Everything below yields
		-- (HTTP, sleep, dialogs, catalog write) and Lua 5.1 cannot yield across
		-- a C-level pcall boundary -> "Yielding is not allowed within a C or
		-- metamethod call".
		local tmpPath
		local ok, errMsg = LrFunctionContext.pcallWithContext('pmtagger_run', function()

			progress:setCaption('Rendering image…')
			local jpegData, path, jErr = getJpeg(photo, 1024)
			tmpPath = path
			if not jpegData then error(jErr or 'Could not read image.') end

			local suggestions = {}
			local warnings = {}

			-- Pl@ntNet (needs a file on disk).
			if prefs.plantNetApiKey and prefs.plantNetApiKey ~= '' and tmpPath then
				progress:setCaption('Asking Pl@ntNet…')
				local res, err = PlantNetAPI.identify(
					tmpPath, prefs.plantNetApiKey, prefs.plantNetProject, prefs.defaultOrgan)
				if res then
					for _, s in ipairs(res) do table.insert(suggestions, s) end
				elseif err then
					table.insert(warnings, err)
				end
			end

			-- iNaturalist (needs a file on disk; uses photo GPS if present).
			-- getApiToken() transparently refreshes the JWT via OAuth.
			if inatReady and tmpPath then
				progress:setCaption('Authenticating with iNaturalist…')
				local jwt, tokErr = iNatAuth.getApiToken()
				if not jwt then
					table.insert(warnings, tokErr or 'iNaturalist authentication failed.')
				else
					progress:setCaption('Asking iNaturalist…')

					local lat, lng
					local gps = photo:getRawMetadata('gps')
					if type(gps) == 'table' then
						lat, lng = gps.latitude, gps.longitude
					end

					local iRes, iErr = iNaturalistAPI.identify(tmpPath, jwt, lat, lng)
					if iRes then
						for _, s in ipairs(iRes) do table.insert(suggestions, s) end
					elseif iErr then
						table.insert(warnings, iErr)
					end
				end
			end

			progress:done()

			-- Split PlantNet vs Google before merging so the merge helper can
			-- reconcile duplicates and combine sources.
			local merged = mergeSuggestions(suggestions, {})

			if #merged == 0 then
				local msg = 'No suggestions were returned.'
				if #warnings > 0 then msg = msg .. '\n\n' .. table.concat(warnings, '\n') end
				LrDialogs.message('Plant & Mushroom Tagger', msg, 'info')
				return
			end

			local chosen = showPicker(merged)
			if not chosen then return end -- user cancelled

			applyTag(catalog, photo, chosen)

			LrDialogs.showBezel('Tagged: ' .. chosen.name)
		end)

		progress:done()

		if tmpPath and LrFileUtils.exists(tmpPath) then
			pcall(function() LrFileUtils.delete(tmpPath) end)
		end

		if not ok then
			LrDialogs.message('Plant & Mushroom Tagger',
				'Something went wrong:\n\n' .. tostring(errMsg), 'critical')
		end
	end)
end)
