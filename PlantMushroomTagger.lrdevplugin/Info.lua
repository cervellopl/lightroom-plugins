--[[----------------------------------------------------------------------------
Info.lua
Plugin manifest for the Plant & Mushroom Tagger.
------------------------------------------------------------------------------]]

return {

	LrSdkVersion = 12.0,
	LrSdkMinimumVersion = 6.0, -- Lightroom 6 / Classic

	LrToolkitIdentifier = 'pl.cervello.plantmushroomtagger',
	LrPluginName = 'Plant & Mushroom Tagger',

	-- Where the user enters API keys and options.
	LrPluginInfoProvider = 'PluginInfoProvider.lua',

	-- Custom metadata fields the plugin can write into.
	LrMetadataProvider = 'MetadataDefinition.lua',

	-- Menu entry under  Library > Plug-in Extras.
	-- (Plain "..." instead of the Unicode ellipsis so that external tools such
	--  as AutoHotkey can match the menu title reliably.)
	LrLibraryMenuItems = {
		{
			title = 'Identify Plant / Mushroom...',
			file = 'IdentifyPlant.lua',
		},
	},

	-- Same command also under  File > Plug-in Extras  (a second access point,
	-- since the SDK does not allow adding to the right-click context menu).
	LrExportMenuItems = {
		{
			title = 'Identify Plant / Mushroom...',
			file = 'IdentifyPlant.lua',
		},
	},

	VERSION = { major = 1, minor = 0, revision = 0 },

}
