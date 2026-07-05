--[[----------------------------------------------------------------------------
Info.lua
Plugin manifest for the Instagram Feed Publisher.
------------------------------------------------------------------------------]]

return {

	LrSdkVersion = 12.0,
	LrSdkMinimumVersion = 6.0, -- Lightroom 6 / Classic

	LrToolkitIdentifier = 'pl.cervello.instagramfeedpublisher',
	LrPluginName = 'Instagram Feed Publisher',

	-- Where the user enters the Instagram Graph API token, account id and the
	-- image-host credentials.
	LrPluginInfoProvider = 'PluginInfoProvider.lua',

	-- Custom metadata fields recording what was published and where.
	LrMetadataProvider = 'MetadataDefinition.lua',

	-- Menu entry under  Library > Plug-in Extras.
	-- (Plain "..." instead of the Unicode ellipsis so that external tools such
	--  as AutoHotkey can match the menu title reliably.)
	LrLibraryMenuItems = {
		{
			title = 'Publish to Instagram Feed...',
			file = 'PublishToInstagram.lua',
		},
	},

	-- Same command also under  File > Plug-in Extras  (a second access point,
	-- since the SDK does not allow adding to the right-click context menu).
	LrExportMenuItems = {
		{
			title = 'Publish to Instagram Feed...',
			file = 'PublishToInstagram.lua',
		},
	},

	VERSION = { major = 1, minor = 0, revision = 0 },

}
