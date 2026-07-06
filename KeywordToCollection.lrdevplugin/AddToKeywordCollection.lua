--[[----------------------------------------------------------------------------
AddToKeywordCollection.lua
Main workflow, launched from  Library > Plug-in Extras >
"Add to Keyword Collection…".

For every selected photo it looks at the assigned keywords and, for each
keyword, makes sure a collection with the same name exists (creating it when it
does not) and adds the photo to that collection. Works on any number of
selected photos at once.

Two ways to organize the collections (chosen at run time):
  * Flat       – one collection per keyword name.
  * Hierarchy  – recreate the keyword tree as nested collection sets, with the
                 keyword itself as a collection inside its parent set.

Options are remembered between runs.
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
if prefs.structureMode  == nil then prefs.structureMode  = 'flat' end -- 'flat' | 'hierarchy'
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

-- Collect the keyword names to use for one photo, de-duplicated (ordered array
-- of { name = <string> }).
--
-- This LR build rejects the raw-metadata key "keywordTags", so we read the
-- formatted (string) metadata instead:
--   * keywordTags          -> the keywords directly applied to the photo.
--   * keywordTagsForExport -> also includes ancestor keywords / synonyms that
--                             are flagged to export (used for "parent keywords"
--                             in flat mode).
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

-- Walk the catalog's keyword tree and map each keyword name (lower-cased) to the
-- ordered list of its ancestor names (top-level first, immediate parent last).
-- On duplicate names the first one encountered wins.
local function buildKeywordAncestry(catalog)
	local index = {}

	local function walk(keyword, ancestors)
		local name = trim(keyword:getName())
		if name ~= '' then
			local key = name:lower()
			if index[key] == nil then
				index[key] = ancestors
			end
		end

		-- Path passed down to children = ancestors + this keyword.
		local childAncestors = {}
		for _, a in ipairs(ancestors) do childAncestors[#childAncestors + 1] = a end
		childAncestors[#childAncestors + 1] = name

		local children = keyword:getChildren()
		if children then
			for _, child in ipairs(children) do
				walk(child, childAncestors)
			end
		end
	end

	local tops = catalog:getKeywords()
	if tops then
		for _, top in ipairs(tops) do
			walk(top, {})
		end
	end
	return index
end

--------------------------------------------------------------------------------
-- Options dialog
--------------------------------------------------------------------------------

-- De-duplicated preview of the keyword names found across all selected photos.
-- In hierarchy mode only the directly-applied (leaf) keywords are listed, since
-- the parents become collection sets automatically.
local function previewKeywords(photos, includeParents, mode)
	local effectiveParents = (mode ~= 'hierarchy') and includeParents or false
	local names, seen = {}, {}
	for _, photo in ipairs(photos) do
		for _, entry in ipairs(keywordsForPhoto(photo, effectiveParents)) do
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
		props.structureMode   = prefs.structureMode
		props.groupInSet      = prefs.groupInSet
		props.setName         = prefs.setName
		props.includeParents  = prefs.includeParents
		props.keywordPreview  = previewKeywords(photos, prefs.includeParents, prefs.structureMode)

		local function refreshPreview()
			props.keywordPreview =
				previewKeywords(photos, props.includeParents, props.structureMode)
		end
		props:addObserver('includeParents', refreshPreview)
		props:addObserver('structureMode', refreshPreview)

		local f = LrView.osFactory()
		local contents = f:column {
			bind_to_object = props,
			spacing = f:control_spacing(),

			f:static_text {
				title = 'Each selected photo is added to a collection named after\n'
				      .. 'every keyword it carries. Missing collections (and sets)\n'
				      .. 'are created automatically.',
				height_in_lines = 3,
			},

			f:static_text { title = 'Organize collections as:' },
			f:radio_button {
				title = 'Flat  (one collection per keyword)',
				value = LrView.bind 'structureMode',
				checked_value = 'flat',
			},
			f:radio_button {
				title = 'Mirror keyword hierarchy  (nested collection sets)',
				value = LrView.bind 'structureMode',
				checked_value = 'hierarchy',
			},

			f:checkbox {
				title = 'Also use parent keywords (flat mode only)',
				value = LrView.bind 'includeParents',
				enabled = LrView.bind {
					key = 'structureMode',
					transform = function(v) return v == 'flat' end,
				},
			},

			f:spacer { height = 6 },

			f:static_text { title = 'Keywords detected:' },
			f:static_text {
				title = LrView.bind 'keywordPreview',
				width_in_chars = 46,
				height_in_lines = 4,
			},

			f:row {
				f:checkbox {
					title = 'Place everything inside a set named:',
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
			prefs.structureMode  = props.structureMode
			prefs.groupInSet     = props.groupInSet
			prefs.setName        = trim(props.setName)
			prefs.includeParents = props.includeParents
			chosen = {
				structureMode  = prefs.structureMode,
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

		-- For hierarchy mode we need the keyword tree. Build it up front (reads
		-- only) so a failure here aborts cleanly before any catalog changes.
		local ancestry = {}
		if opts.structureMode == 'hierarchy' then
			-- pcallWithContext (not raw pcall): reading the keyword tree may
			-- yield, which a C-level pcall cannot cross.
			local ok, res = LrFunctionContext.pcallWithContext('ktc_ancestry',
				function() return buildKeywordAncestry(catalog) end)
			if not ok then
				LrDialogs.message('Add to Keyword Collection',
					'Could not read the keyword hierarchy: ' .. tostring(res), 'error')
				return
			end
			ancestry = res
		end

		local progress = LrProgressScope {
			title = 'Adding photos to keyword collections',
			functionContext = context,
		}

		-- Caches so each set / collection is created at most once.
		local setCache        = {}
		local collectionCache = {}

		local stats = {
			photosProcessed = 0,
			photosSkipped   = 0, -- had no keywords
			additions       = 0, -- photo↔collection links made
			errors          = 0, -- keywords that could not be turned into a collection
			firstError      = nil, -- text of the first failure, for diagnostics
		}

		local ok, err = catalog:withWriteAccessDo('Add to Keyword Collection', function()

			-- The optional top-level container set, shared by both modes.
			local baseSet, baseKey = nil, 'root'
			if opts.groupInSet then
				baseSet = catalog:createCollectionSet(opts.setName, nil, true)
				baseKey = 'set:' .. opts.setName:lower()
			end

			-- Ensure the nested collection-set path for a list of ancestor names,
			-- returning the deepest set and its cache key.
			local function ensureSetPath(ancestors)
				local parent, pathKey = baseSet, baseKey
				for _, aname in ipairs(ancestors) do
					if trim(aname) ~= '' then
						pathKey = pathKey .. '/' .. aname:lower()
						local s = setCache[pathKey]
						if not s then
							s = catalog:createCollectionSet(aname, parent, true)
							setCache[pathKey] = s
						end
						parent = s
					end
				end
				return parent, pathKey
			end

			-- Ensure a collection with the given name under a parent set.
			local function ensureCollection(name, parentSet, cacheKey)
				local existing = collectionCache[cacheKey]
				if existing then return existing end
				local coll = catalog:createCollection(name, parentSet, true)
				collectionCache[cacheKey] = coll
				return coll
			end

			-- Resolve the target collection for one keyword name.
			local function collectionFor(name)
				if opts.structureMode == 'hierarchy' then
					local ancestors = ancestry[name:lower()] or {}
					local parentSet, pathKey = ensureSetPath(ancestors)
					return ensureCollection(name, parentSet, pathKey .. '/coll:' .. name:lower())
				else
					return ensureCollection(name, baseSet, baseKey .. '/coll:' .. name:lower())
				end
			end

			for i, photo in ipairs(photos) do
				if progress:isCanceled() then break end

				-- In hierarchy mode use only the directly-applied keywords.
				local useParents = (opts.structureMode == 'flat') and opts.includeParents or false
				local kws = keywordsForPhoto(photo, useParents)

				if #kws == 0 then
					stats.photosSkipped = stats.photosSkipped + 1
				else
					stats.photosProcessed = stats.photosProcessed + 1
					for _, entry in ipairs(kws) do
						-- pcallWithContext, not pcall: creating collections/sets
						-- yields, so a C-level pcall would raise "Yielding is not
						-- allowed within a C or metamethod call".
						local okColl, coll = LrFunctionContext.pcallWithContext('ktc_coll',
							function() return collectionFor(entry.name) end)
						if okColl and coll then
							coll:addPhotos({ photo })
							stats.additions = stats.additions + 1
						else
							stats.errors = stats.errors + 1
							if not stats.firstError then
								stats.firstError = string.format('"%s": %s',
									entry.name, tostring(coll))
							end
						end
					end
				end

				progress:setPortionComplete(i, #photos)
			end
		end, { timeout = 120 })

		local collectionsTouched = 0
		for _ in pairs(collectionCache) do collectionsTouched = collectionsTouched + 1 end
		local setsTouched = 0
		for _ in pairs(setCache) do setsTouched = setsTouched + 1 end

		progress:done()

		if not ok then
			LrDialogs.message('Add to Keyword Collection',
				'Could not update the catalog: ' .. tostring(err), 'error')
			return
		end

		local msg = string.format(
			'%d photo(s) processed.\n' ..
			'%d link(s) made across %d collection(s)%s.',
			stats.photosProcessed, stats.additions, collectionsTouched,
			(setsTouched > 0) and (' in ' .. setsTouched .. ' set(s)') or '')
		if stats.photosSkipped > 0 then
			msg = msg .. string.format('\n%d photo(s) had no keywords and were skipped.',
				stats.photosSkipped)
		end
		if stats.errors > 0 then
			msg = msg .. string.format('\n%d keyword(s) could not be turned into a collection.',
				stats.errors)
			if stats.firstError then
				msg = msg .. '\n\nFirst error — ' .. stats.firstError
			end
		end

		LrDialogs.message('Add to Keyword Collection', msg, 'info')
	end)
end)
