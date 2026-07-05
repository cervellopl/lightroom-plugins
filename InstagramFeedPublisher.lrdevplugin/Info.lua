--[[----------------------------------------------------------------------------
Info.lua
Plugin manifest for the Instagram Feed Publisher.

This plugin is a Lightroom *Publish Service*: it appears in the Library's
Publish Services panel (like the built-in Flickr publisher). You add photos to
its published collection and click Publish; Lightroom renders each photo and the
plugin posts it to your Instagram feed, then tracks what has been published.
------------------------------------------------------------------------------]]

return {

	LrSdkVersion = 12.0,
	LrSdkMinimumVersion = 6.0, -- Lightroom 6 / Classic

	LrToolkitIdentifier = 'pl.cervello.instagramfeedpublisher',
	LrPluginName = 'Instagram Feed Publisher',

	-- Global credentials (access token, account id, Imgur Client ID) live here,
	-- in  File > Plug-in Manager > Instagram Feed Publisher.
	LrPluginInfoProvider = 'PluginInfoProvider.lua',

	-- The Publish Service itself (shown in the Library "Publish Services" panel).
	LrExportServiceProvider = {
		title = 'Instagram Feed',
		file = 'InstagramPublishServiceProvider.lua',
	},

	VERSION = { major = 2, minor = 0, revision = 0 },

}
