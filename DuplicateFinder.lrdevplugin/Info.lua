--[[----------------------------------------------------------------------------
Info.lua
Plugin manifest for "Duplicate Finder".

Scans the selected photos (or the photos of the active source) for duplicate
images and, optionally, gathers the duplicates into a collection, labels them,
and/or selects them in the grid for review.
------------------------------------------------------------------------------]]

return {

	LrSdkVersion = 12.0,
	LrSdkMinimumVersion = 6.0, -- Lightroom 6 / Classic

	LrToolkitIdentifier = 'pl.cervello.duplicatefinder',
	LrPluginName = 'Duplicate Finder',

	-- Menu entry under  Library > Plug-in Extras.
	-- (Plain "..." instead of the Unicode ellipsis so external tools such as
	--  AutoHotkey can match the menu title reliably.)
	LrLibraryMenuItems = {
		{
			title = 'Find Duplicate Photos...',
			file = 'FindDuplicates.lua',
		},
	},

	-- Same command also under  File > Plug-in Extras  (a second access point).
	LrExportMenuItems = {
		{
			title = 'Find Duplicate Photos...',
			file = 'FindDuplicates.lua',
		},
	},

	VERSION = { major = 1, minor = 0, revision = 0 },

}
