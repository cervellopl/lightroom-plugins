--[[----------------------------------------------------------------------------
FindDuplicates.lua
Main workflow, launched from  Library > Plug-in Extras >
"Find Duplicate Photos…".

Looks at the target photos (the current selection, or – if nothing is
specifically selected – every photo in the active source / collection) and
groups together images that match on the criteria you pick:

  * Capture date/time      (EXIF DateTimeOriginal)
  * File size              (bytes on disk)
  * Pixel dimensions       (original width × height)
  * Original file name     (e.g. "IMG_1234.CR2", ignoring the folder)
  * Exact file contents    (MD5 of the file on disk – the most reliable test,
                            but it must read every candidate file, so it is
                            slower)

Any group with two or more members is a set of duplicates. Within each group
one photo is kept as the "master" (the earliest capture time, then the
alphabetically first path); the rest are the duplicates that the chosen actions
act on. You can instead flag every copy in the group.

Actions (any combination):
  * Add the duplicates to a collection (created if missing).
  * Add a keyword to the duplicates (created if missing).
  * Give the duplicates a colour label.
  * Select the duplicates in the grid so you can review / delete them yourself.

The plugin never deletes photos or files – deciding what to remove stays with
you.

Notes learned the hard way about this LR build:
  * Catalog writes (creating collections, setting metadata) yield, so they are
    wrapped with LrFunctionContext.pcallWithContext, never a C-level pcall.

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
local LrFileUtils        = import 'LrFileUtils'
local LrMD5              = import 'LrMD5'

local prefs = LrPrefs.prefsForPlugin()

-- First-run defaults.
if prefs.matchTime      == nil then prefs.matchTime      = true  end
if prefs.matchSize      == nil then prefs.matchSize      = true  end
if prefs.matchDimensions== nil then prefs.matchDimensions= false end
if prefs.matchName      == nil then prefs.matchName      = false end
if prefs.matchContents  == nil then prefs.matchContents  = false end
if prefs.ignoreVirtual  == nil then prefs.ignoreVirtual  = true  end
if prefs.flagAll        == nil then prefs.flagAll        = false end -- false = keep one master per group

if prefs.doCollection   == nil then prefs.doCollection   = true  end
if prefs.collectionName == nil then prefs.collectionName = 'Duplicates' end
if prefs.doLabel        == nil then prefs.doLabel        = false end
if prefs.labelColor     == nil then prefs.labelColor     = 'Red' end
if prefs.doKeyword      == nil then prefs.doKeyword      = false end
if prefs.keywordName    == nil then prefs.keywordName    = 'duplicate' end
if prefs.doSelect       == nil then prefs.doSelect       = true  end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function trim(s)
	return (tostring(s or ''):gsub('^%s*(.-)%s*$', '%1'))
end

-- Base file name (strip any directory part) from a full path.
local function baseName(path)
	if not path or path == '' then return '' end
	return (path:gsub('.*[/\\]', ''))
end

-- Read whichever attributes are needed once, so we don't hit the catalog
-- repeatedly. Returns a table describing the photo, or nil to skip it.
local function describe(photo, opts)
	local info = { photo = photo }

	info.path        = photo:getRawMetadata('path')
	info.isVirtual   = photo:getRawMetadata('isVirtualCopy') and true or false
	info.captureTime = photo:getRawMetadata('dateTimeOriginal')      -- number | nil
	info.fileSize    = photo:getRawMetadata('fileSize')             -- number | nil (may be nil for RAW+missing)
	-- Dimensions come from *formatted* metadata (e.g. "6000 x 4000"); the raw
	-- croppedWidth/Height keys are rejected by this LR build. croppedDimensions
	-- reflects the current pixel size; fall back to the original dimensions.
	info.dims        = photo:getFormattedMetadata('croppedDimensions')
	                or photo:getFormattedMetadata('dimensions')
	info.fileName    = photo:getFormattedMetadata('fileName') or baseName(info.path)

	return info
end

-- Build the cheap (no file-reading) signature for a photo from the selected
-- metadata criteria. Returns a string, or nil when a required attribute is
-- missing (such a photo cannot be reliably matched and is skipped).
local function cheapSignature(info, opts)
	local parts = {}
	if opts.matchTime then
		if not info.captureTime then return nil end
		parts[#parts + 1] = 't=' .. string.format('%.0f', info.captureTime)
	end
	if opts.matchSize then
		if not info.fileSize then return nil end
		parts[#parts + 1] = 's=' .. tostring(info.fileSize)
	end
	if opts.matchDimensions then
		if not info.dims or info.dims == '' then return nil end
		parts[#parts + 1] = 'd=' .. info.dims
	end
	if opts.matchName then
		parts[#parts + 1] = 'n=' .. info.fileName:lower()
	end
	-- No cheap criteria selected (contents-only run): everything shares one
	-- bucket and MD5 does the separating.
	if #parts == 0 then return '*' end
	return table.concat(parts, '|')
end

-- Deterministic ordering so the "master" of a group is stable between runs:
-- earliest capture time first, then lowest path, then catalog id.
local function orderKey(info)
	local t = info.captureTime or math.huge
	return string.format('%020.3f|%s|%s',
		t, tostring(info.path or ''), tostring(info.photo.localIdentifier or ''))
end

--------------------------------------------------------------------------------
-- Options dialog
--------------------------------------------------------------------------------

local function showOptionsDialog(photoCount)
	local chosen
	LrFunctionContext.callWithContext('dup_options', function(context)
		local props = LrBinding.makePropertyTable(context)
		for _, k in ipairs({
			'matchTime','matchSize','matchDimensions','matchName','matchContents',
			'ignoreVirtual','flagAll','doCollection','collectionName',
			'doLabel','labelColor','doKeyword','keywordName','doSelect',
		}) do
			props[k] = prefs[k]
		end

		local f = LrView.osFactory()
		local labels = { 'Red', 'Yellow', 'Green', 'Blue', 'Purple' }
		local labelItems = {}
		for _, name in ipairs(labels) do
			labelItems[#labelItems + 1] = { title = name, value = name }
		end

		local contents = f:column {
			bind_to_object = props,
			spacing = f:control_spacing(),

			f:static_text {
				title = string.format(
					'Scan %d photo(s) for duplicates.\n' ..
					'Two photos are duplicates when they match on every ticked test:',
					photoCount),
				height_in_lines = 2,
			},

			f:checkbox { title = 'Same capture date/time', value = LrView.bind 'matchTime' },
			f:checkbox { title = 'Same file size',          value = LrView.bind 'matchSize' },
			f:checkbox { title = 'Same pixel dimensions',   value = LrView.bind 'matchDimensions' },
			f:checkbox { title = 'Same original file name', value = LrView.bind 'matchName' },
			f:checkbox {
				title = 'Same exact file contents (MD5 – reliable but slower)',
				value = LrView.bind 'matchContents',
			},

			f:spacer { height = 6 },
			f:checkbox { title = 'Ignore virtual copies', value = LrView.bind 'ignoreVirtual' },
			f:checkbox {
				title = 'Flag every copy (otherwise keep the earliest as the master)',
				value = LrView.bind 'flagAll',
			},

			f:spacer { height = 8 },
			f:static_text { title = 'When duplicates are found:' },

			f:row {
				f:checkbox {
					title = 'Add them to collection:',
					value = LrView.bind 'doCollection',
				},
				f:edit_field {
					value = LrView.bind 'collectionName',
					width_in_chars = 18,
					enabled = LrView.bind 'doCollection',
				},
			},
			f:row {
				f:checkbox {
					title = 'Set colour label:',
					value = LrView.bind 'doLabel',
				},
				f:popup_menu {
					value = LrView.bind 'labelColor',
					items = labelItems,
					enabled = LrView.bind 'doLabel',
				},
			},
			f:row {
				f:checkbox {
					title = 'Add keyword:',
					value = LrView.bind 'doKeyword',
				},
				f:edit_field {
					value = LrView.bind 'keywordName',
					width_in_chars = 18,
					enabled = LrView.bind 'doKeyword',
				},
			},
			f:checkbox {
				title = 'Select the duplicates in the grid',
				value = LrView.bind 'doSelect',
			},
		}

		local result = LrDialogs.presentModalDialog {
			title = 'Find Duplicate Photos',
			contents = contents,
			actionVerb = 'Scan',
		}

		if result == 'ok' then
			for _, k in ipairs({
				'matchTime','matchSize','matchDimensions','matchName','matchContents',
				'ignoreVirtual','flagAll','doCollection','doLabel','labelColor','doKeyword','doSelect',
			}) do
				prefs[k] = props[k]
			end
			prefs.collectionName = trim(props.collectionName)
			prefs.keywordName    = trim(props.keywordName)
			chosen = {}
			for _, k in ipairs({
				'matchTime','matchSize','matchDimensions','matchName','matchContents',
				'ignoreVirtual','flagAll','doCollection','doLabel','labelColor','doKeyword','doSelect',
			}) do
				chosen[k] = prefs[k]
			end
			chosen.collectionName = prefs.collectionName
			chosen.keywordName    = prefs.keywordName
		end
	end)
	return chosen
end

--------------------------------------------------------------------------------
-- Duplicate detection
--------------------------------------------------------------------------------

-- Returns an array of groups; each group is an array of `info` tables (>= 2
-- members) that are duplicates of one another, sorted by orderKey so the first
-- element is the master.
local function findDuplicateGroups(photos, opts, progress)
	-- Pass 1: bucket by the cheap signature.
	local buckets, order = {}, {}
	for i, photo in ipairs(photos) do
		if progress and progress:isCanceled() then return nil end
		local info = describe(photo, opts)
		local skip = opts.ignoreVirtual and info.isVirtual
		local sig  = (not skip) and cheapSignature(info, opts) or nil
		if sig then
			local b = buckets[sig]
			if not b then b = {}; buckets[sig] = b; order[#order + 1] = sig end
			b[#b + 1] = info
		end
		if progress then progress:setPortionComplete(i, #photos * 2) end
	end

	-- Pass 2: within each candidate bucket, optionally refine by MD5. Only
	-- buckets with 2+ members can hold duplicates, so we never hash a file that
	-- is already unique on the cheap criteria.
	local groups = {}
	local processed = 0
	local total = #photos -- rough denominator for the hashing half of progress

	for _, sig in ipairs(order) do
		local bucket = buckets[sig]
		if #bucket >= 2 then
			if opts.matchContents then
				local sub, suborder = {}, {}
				for _, info in ipairs(bucket) do
					if progress and progress:isCanceled() then return nil end
					local hash
					local ok, data = LrFunctionContext.pcallWithContext('dup_read',
						function() return LrFileUtils.readFile(info.path) end)
					if ok and data then
						hash = LrMD5.digest(data)
					else
						hash = 'ERR:' .. tostring(info.path) -- keeps unreadable files apart
					end
					local key = sig .. '#' .. hash
					local s = sub[key]
					if not s then s = {}; sub[key] = s; suborder[#suborder + 1] = key end
					s[#s + 1] = info

					processed = processed + 1
					if progress then
						progress:setPortionComplete(#photos + math.min(processed, total), #photos * 2)
					end
				end
				for _, key in ipairs(suborder) do
					if #sub[key] >= 2 then groups[#groups + 1] = sub[key] end
				end
			else
				groups[#groups + 1] = bucket
			end
		end
	end

	-- Sort every group so element 1 is the master.
	for _, g in ipairs(groups) do
		table.sort(g, function(a, b) return orderKey(a) < orderKey(b) end)
	end
	return groups
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

LrTasks.startAsyncTask(function()
	LrFunctionContext.callWithContext('dup_main', function(context)

		local catalog = LrApplication.activeCatalog()
		local photos  = catalog:getTargetPhotos()

		if not photos or #photos == 0 then
			LrDialogs.message('Find Duplicate Photos',
				'No photos to scan. Select some photos (or open a collection) and try again.',
				'info')
			return
		end

		local opts = showOptionsDialog(#photos)
		if not opts then return end -- user cancelled

		if not (opts.matchTime or opts.matchSize or opts.matchDimensions
			or opts.matchName or opts.matchContents) then
			LrDialogs.message('Find Duplicate Photos',
				'Pick at least one test to match photos on.', 'warning')
			return
		end
		if opts.doCollection and opts.collectionName == '' then
			LrDialogs.message('Find Duplicate Photos',
				'Please provide a name for the collection.', 'warning')
			return
		end
		if opts.doKeyword and opts.keywordName == '' then
			LrDialogs.message('Find Duplicate Photos',
				'Please provide a keyword to add.', 'warning')
			return
		end

		local progress = LrProgressScope {
			title = 'Scanning for duplicate photos',
			functionContext = context,
		}

		local groups = findDuplicateGroups(photos, opts, progress)
		progress:done()

		if groups == nil then return end -- cancelled

		if #groups == 0 then
			LrDialogs.message('Find Duplicate Photos',
				'No duplicates found among the ' .. #photos .. ' photo(s) scanned.', 'info')
			return
		end

		-- Collect the photos to act on: the duplicates (all but the master),
		-- or every copy when "flag all" is on.
		local dupInfos = {}
		local totalCopies = 0
		for _, g in ipairs(groups) do
			totalCopies = totalCopies + #g
			local startAt = opts.flagAll and 1 or 2
			for i = startAt, #g do
				dupInfos[#dupInfos + 1] = g[i]
			end
		end

		local dupPhotos = {}
		for _, info in ipairs(dupInfos) do dupPhotos[#dupPhotos + 1] = info.photo end

		-- Apply the write actions (collection + label + keyword) in one catalog
		-- write.
		local actionErr
		if opts.doCollection or opts.doLabel or opts.doKeyword then
			local ok, err = catalog:withWriteAccessDo('Find Duplicate Photos', function()
				if opts.doCollection then
					-- createCollection yields → guard with pcallWithContext.
					local okC, coll = LrFunctionContext.pcallWithContext('dup_coll',
						function() return catalog:createCollection(opts.collectionName, nil, true) end)
					if okC and coll then
						coll:addPhotos(dupPhotos)
					else
						actionErr = 'collection: ' .. tostring(coll)
					end
				end
				if opts.doKeyword then
					-- createKeyword yields too → same guard. Signature:
					-- createKeyword(name, synonyms, includeOnExport, parent, returnExisting)
					local okK, kw = LrFunctionContext.pcallWithContext('dup_kw',
						function()
							return catalog:createKeyword(opts.keywordName, {}, true, nil, true)
						end)
					if okK and kw then
						for _, photo in ipairs(dupPhotos) do
							photo:addKeyword(kw)
						end
					else
						actionErr = actionErr or ('keyword: ' .. tostring(kw))
					end
				end
				if opts.doLabel then
					for _, photo in ipairs(dupPhotos) do
						photo:setRawMetadata('colorNameForLabel', opts.labelColor)
					end
				end
			end, { timeout = 120 })
			if not ok then actionErr = actionErr or tostring(err) end
		end

		-- Select the duplicates in the grid (no write access required).
		if opts.doSelect and #dupPhotos > 0 then
			LrFunctionContext.pcallWithContext('dup_select', function()
				catalog:setSelectedPhotos(dupPhotos[1], dupPhotos)
			end)
		end

		-- Report.
		local msg = string.format(
			'%d duplicate group(s) found across %d matching photo(s).\n' ..
			'%d photo(s) %s.',
			#groups, totalCopies, #dupPhotos,
			opts.flagAll and 'flagged (every copy)' or 'flagged (masters kept)')

		local did = {}
		if opts.doCollection then did[#did + 1] = 'added to "' .. opts.collectionName .. '"' end
		if opts.doKeyword    then did[#did + 1] = 'tagged "' .. opts.keywordName .. '"' end
		if opts.doLabel      then did[#did + 1] = 'labelled ' .. opts.labelColor end
		if opts.doSelect     then did[#did + 1] = 'selected in the grid' end
		if #did > 0 then
			msg = msg .. '\n\nDuplicates were ' .. table.concat(did, ', ') .. '.'
		end
		if actionErr then
			msg = msg .. '\n\nSome actions failed: ' .. actionErr
		end

		LrDialogs.message('Find Duplicate Photos', msg, actionErr and 'warning' or 'info')
	end)
end)
