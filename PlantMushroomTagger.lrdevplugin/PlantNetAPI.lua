--[[----------------------------------------------------------------------------
PlantNetAPI.lua
Wraps the Pl@ntNet v2 identification REST API.

Docs:  https://my.plantnet.org/  ->  "API" (free key after sign-up)
Endpoint: POST https://my-api.plantnet.org/v2/identify/{project}?api-key=KEY
  * multipart/form-data
  * one or more `images` file parts
  * matching `organs` value parts (leaf | flower | fruit | bark | auto)

Returns a normalised list of suggestions:
  { { scientificName=, commonName=, score=, source='Pl@ntNet', family= }, ... }
------------------------------------------------------------------------------]]

local LrHttp = import 'LrHttp'
local json = require 'json'

local PlantNetAPI = {}

-- project: 'all', 'weurope', 'useful', 'k-world-flora', ... 'all' is broadest.
-- Note: Pl@ntNet identifies PLANTS. For fungi, rely on Google Vision (see
-- GoogleVisionAPI.lua). We still call Pl@ntNet because many "mushroom" photos
-- also contain plants, and it does no harm.
function PlantNetAPI.identify(jpegFilePath, apiKey, project, organ)

	if not apiKey or apiKey == '' then
		return nil, 'No Pl@ntNet API key configured.'
	end

	project = project or 'all'
	organ = organ or 'auto'

	local url = string.format(
		'https://my-api.plantnet.org/v2/identify/%s?api-key=%s&include-related-images=false&no-reject=false',
		project, apiKey )

	local content = {
		{ name = 'organs', value = organ },
		{
			name = 'images',
			fileName = 'photo.jpg',
			filePath = jpegFilePath,
			contentType = 'image/jpeg',
		},
	}

	local body, headers = LrHttp.postMultipart(url, content, nil, 30, nil, false)

	if not body then
		local status = headers and headers.error and headers.error.name or 'unknown'
		return nil, 'Pl@ntNet request failed (' .. tostring(status) .. ').'
	end

	local ok, parsed = pcall(json.decode, body)
	if not ok or type(parsed) ~= 'table' then
		return nil, 'Could not parse Pl@ntNet response.'
	end

	if parsed.statusCode and parsed.statusCode >= 400 then
		return nil, 'Pl@ntNet error: ' .. tostring(parsed.message or parsed.error or parsed.statusCode)
	end

	if type(parsed.results) ~= 'table' then
		return {}, nil
	end

	local suggestions = {}
	for _, r in ipairs(parsed.results) do
		local sp = r.species or {}
		local common = ''
		if type(sp.commonNames) == 'table' and sp.commonNames[1] then
			common = sp.commonNames[1]
		end
		table.insert(suggestions, {
			scientificName = sp.scientificNameWithoutAuthor or sp.scientificName or '',
			commonName = common,
			family = (sp.family and sp.family.scientificNameWithoutAuthor) or '',
			score = tonumber(r.score) or 0,
			source = 'Pl@ntNet',
		})
	end

	return suggestions, nil
end

return PlantNetAPI
