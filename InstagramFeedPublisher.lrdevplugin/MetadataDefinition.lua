--[[----------------------------------------------------------------------------
MetadataDefinition.lua
Custom metadata fields written after a successful publish. They appear in the
Library Metadata panel under a custom set and are searchable, so you can quickly
filter for photos you have already posted.
------------------------------------------------------------------------------]]

return {

	metadataFieldsForPhotos = {
		{
			id = 'instagramMediaId',
			title = 'Instagram Media ID',
			dataType = 'string',
			searchable = true,
			browsable = true,
		},
		{
			id = 'instagramPermalink',
			title = 'Instagram Permalink',
			dataType = 'url',
			searchable = true,
			browsable = true,
		},
		{
			id = 'instagramPublishedAt',
			title = 'Instagram Published At',
			dataType = 'string',
			searchable = true,
			browsable = true,
		},
	},

	schemaVersion = 1,

}
