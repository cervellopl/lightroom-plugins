--[[----------------------------------------------------------------------------
AddToKeywordCollection.lua
Main workflow, launched from  Library > Plug-in Extras >
"Add to Keyword Collection…".

For every selected photo it looks at the assigned keywords and, for each
keyword, makes sure a collection with the same name exists (creating it when it
does not) and adds the photo to that collection.

Options (remembered between runs):
  * Group the collections inside a collection set.
  * Also use the parent/ancestor keywords, not just the ones directly applied.
------------------------------------------------------------------------------]]

local LrApplication      = import 'LrApplication'
local LrTasks            = import 'LrTasks'
local LrDialogs          = import 'LrDialogs'
local LrFunctionContext  = import 'LrFunctionContext'
local LrBinding          = import 'LrBinding'
local LrView             = import 'LrView'
local LrPrefs            = import 'LrPrefs'
local LrProgressScope    = import 'LrProgressScope'

local prefs = LrPrefs.prefsForPlugin()

-- First-run defaults.
if prefs.groupInSet     == nil then prefs.groupInSet     = false end
if prefs.setName        == nil then prefs.setName        = 'Keywords' end
if prefs.includeParents == nil then prefs.includeParents = false end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Trim surrounding whitespace.
local function trim(s)
	return (tostring(s or ''):gsub('^%s*(.-)%s*$', '%1'))
end

-- Split a comma-separated keyword string into trimmed, non-empty names.
local function splitKeywordString(s)
	local out = {}
	for part in tostring(s or ''):gmatch('[^,]+') do
		local name = trim(part)
		if name ~= '' then
			out[#out + 1] = name
		end
	end
	return out
end

-- Collect the keyword names to use for one photo, de-duplicated.
-- Returns an ordered array of { name = <string> }.
--
-- This LR build rejects the raw-metadata key "keywordTags", so we read the
-- formatted (string) metadata instead:
--   * keywordTags          -> the keywords directly applied to the photo.
--   * keywordTagsForExport -> also includes ancestor keywords / synonyms that
--                             are flagged to export, which is what we use when
--                             "Also use parent keywords" is enabled.
local function keywordsForPhoto(photo, includeParents)
	local key = includeParents and 'keywordTagsForExport' or 'keywordTags'
	local str = photo:getFormattedMetadata(key)

	local result, seen = {}, {}
	for _, name in ipairs(splitKeywordString(str)) do
		if not seen[name] then
			seen[name] = true
			result[#result + 1] = { name = name }
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- Options dialog
--------------------------------------------------------------------------------

-- Build a de-duplicated preview of the keyword names found across all the
-- selected photos, honouring the "include parents" toggle.
local function previewKeywords(photos, includeParents)
	local names, seen = {}, {}
	for _, photo in ipairs(photos) do
		for _, entry in ipairs(keywordsForPhoto(photo, includeParents)) do
			if not seen[entry.name] then
				seen[entry.name] = true
				names[#names + 1] = entry.name
			end
		end
	end
	table.sort(names)
	if #names == 0 then
		return '(none found on the selected photo' .. (#photos == 1 and '' or 's') .. ')'
	end
	return table.concat(names, ', ')
end

local function showOptionsDialog(photos)
	local chosen
	LrFunctionContext.callWithContext('ktc_options', function(context)
		local props = LrBinding.makePropertyTable(context)
		props.groupInSet      = prefs.groupInSet
		props.setName         = prefs.setName
		props.includeParents  = prefs.includeParents
		props.keywordPreview  = previewKeywords(photos, prefs.includeParents)

		-- Keep the preview in sync with the "parent keywords" checkbox.
		props:addObserver('includeParents', function()
			props.keywordPreview = previewKeywords(photos, props.includeParents)
		end)

		local f = LrView.osFactory()
		local contents = f:column {
			bind_to_object = props,
			spacing = f:control_spacing(),

			f:static_text {
				title = 'Each selected photo will be added to a collection\n'
				      .. 'named after every keyword it carries. Missing\n'
				      .. 'collections are created automatically.',
				height_in_lines = 3,
			},

			f:checkbox {
				title = 'Also use parent keywords',
				value = LrView.bind 'includeParents',
			},

			f:static_text {
				title = 'Keywords detected:',
			},
			f:static_text {
				title = LrView.bind 'keywordPreview',
				width_in_chars = 44,
				height_in_lines = 4,
			},

			f:row {
				f:checkbox {
					title = 'Group collections in a set named:',
					value = LrView.bind 'groupInSet',
				},
				f:edit_field {
					value = LrView.bind 'setName',
					width_in_chars = 16,
					enabled = LrView.bind 'groupInSet',
				},
			},
		}

		local result = LrDialogs.presentModalDialog {
			title = 'Add to Keyword Collection',
			contents = contents,
			actionVerb = 'Run',
		}

		if result == 'ok' then
			prefs.groupInSet     = props.groupInSet
			prefs.setName        = trim(props.setName)
			prefs.includeParents = props.includeParents
			chosen = {
				groupInSet     = prefs.groupInSet,
				setName        = prefs.setName,
				includeParents = prefs.includeParents,
			}
		end
	end)
	return chosen
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

LrTasks.startAsyncTask(function()
	LrFunctionContext.callWithContext('ktc_main', function(context)

		local catalog = LrApplication.activeCatalog()
		local photos  = catalog:getTargetPhotos()

		if not photos or #photos == 0 then
			LrDialogs.message('Add to Keyword Collection',
				'No photos are selected. Select one or more photos and try again.',
				'info')
			return
		end

		local opts = showOptionsDialog(photos)
		if not opts then return end -- user cancelled

		if opts.groupInSet and opts.setName == '' then
			LrDialogs.message('Add to Keyword Collection',
				'Please provide a name for the collection set.', 'warning')
			return
		end

		local progress = LrProgressScope {
			title = 'Adding photos to keyword collections',
			functionContext = context,
		}

		-- Caches so we only touch each collection / set once.
		local collectionCache = {}
		local createdCollections = 0

		local stats = {
			photosProcessed = 0,
			photosSkipped   = 0, -- had no keywords
			additions       = 0, -- photo↔collection links made
		}

		local ok, err = catalog:withWriteAccessDo('Add to Keyword Collection', function()

			-- Resolve the parent collection set once, if grouping is enabled.
			local parentSet = nil
			if opts.groupInSet then
				parentSet = catalog:createCollectionSet(opts.setName, nil, true)
			end

			local function getCollection(name)
				if collectionCache[name] then
					return collectionCache[name]
				end
				-- createCollection returns the existing collection when
				-- canReturnExisting is true, so this both finds and creates.
				local coll = catalog:createCollection(name, parentSet, true)
				collectionCache[name] = coll
				return coll
			end

			for i, photo in ipairs(photos) do
				if progress:isCanceled() then break end

				local kws = keywordsForPhoto(photo, opts.includeParents)

				if #kws == 0 then
					stats.photosSkipped = stats.photosSkipped + 1
				else
					stats.photosProcessed = stats.photosProcessed + 1
					for _, entry in ipairs(kws) do
						local coll = getCollection(entry.name)
						if coll then
							coll:addPhotos({ photo })
							stats.additions = stats.additions + 1
						end
					end
				end

				progress:setPortionComplete(i, #photos)
			end
		end, { timeout = 60 })

		-- Count how many of the cached collections were freshly created is not
		-- directly available from the SDK; report the ones we touched instead.
		local collectionsTouched = 0
		for _ in pairs(collectionCache) do
			collectionsTouched = collectionsTouched + 1
		end

		progress:done()

		if not ok then
			LrDialogs.message('Add to Keyword Collection',
				'Could not update the catalog: ' .. tostring(err), 'error')
			return
		end

		local msg = string.format(
			'%d photo(s) processed.\n' ..
			'%d collection link(s) made across %d keyword collection(s).',
			stats.photosProcessed, stats.additions, collectionsTouched)
		if stats.photosSkipped > 0 then
			msg = msg .. string.format('\n%d photo(s) had no keywords and were skipped.',
				stats.photosSkipped)
		end

		LrDialogs.message('Add to Keyword Collection', msg, 'info')
	end)
end)
