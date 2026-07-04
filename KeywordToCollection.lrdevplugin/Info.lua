--[[----------------------------------------------------------------------------
Info.lua
Plugin manifest for "Keyword to Collection".

Adds each selected photo to a collection named after its keyword(s), creating
the collection when it does not yet exist.
------------------------------------------------------------------------------]]

return {

	LrSdkVersion = 12.0,
	LrSdkMinimumVersion = 6.0, -- Lightroom 6 / Classic

	LrToolkitIdentifier = 'pl.cervello.keywordtocollection',
	LrPluginName = 'Keyword to Collection',

	-- Menu entry under  Library > Plug-in Extras.
	-- (Plain "..." instead of the Unicode ellipsis so external tools such as
	--  AutoHotkey can match the menu title reliably.)
	LrLibraryMenuItems = {
		{
			title = 'Add to Keyword Collection...',
			file = 'AddToKeywordCollection.lua',
		},
	},

	-- Same command also under  File > Plug-in Extras  (a second access point).
	LrExportMenuItems = {
		{
			title = 'Add to Keyword Collection...',
			file = 'AddToKeywordCollection.lua',
		},
	},

	VERSION = { major = 1, minor = 0, revision = 0 },

}
