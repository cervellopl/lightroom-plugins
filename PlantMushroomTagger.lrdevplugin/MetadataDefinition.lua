--[[----------------------------------------------------------------------------
MetadataDefinition.lua
Custom metadata fields written by the plugin. These appear in the Library
Metadata panel under a custom set and are searchable / exportable.
------------------------------------------------------------------------------]]

return {

	metadataFieldsForPhotos = {
		{
			id = 'scientificName',
			title = 'Scientific Name',
			dataType = 'string',
			searchable = true,
			browsable = true,
		},
		{
			id = 'commonName',
			title = 'Common Name',
			dataType = 'string',
			searchable = true,
			browsable = true,
		},
		{
			id = 'idSource',
			title = 'ID Source',
			dataType = 'string',
			searchable = true,
			browsable = true,
		},
		{
			id = 'idConfidence',
			title = 'ID Confidence',
			dataType = 'string',
			searchable = true,
			browsable = true,
		},
	},

	schemaVersion = 1,

}
