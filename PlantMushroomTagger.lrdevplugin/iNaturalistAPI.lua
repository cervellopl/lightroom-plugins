--[[----------------------------------------------------------------------------
iNaturalistAPI.lua
Wraps the iNaturalist computer-vision scoring endpoint. Unlike Pl@ntNet this
covers BOTH plants and fungi (and everything else), and returns real taxonomy:
scientific name, preferred common name, and the "iconic taxon" (Plantae /
Fungi / …) so we can tell a mushroom from a plant.

Endpoint:
  POST https://api.inaturalist.org/v1/computervision/score_image
    * multipart/form-data, file part named `image`
    * optional `lat`, `lng`, `observed_on` to geo-bias results
    * Authorization: Bearer <JWT>

Authentication:
  iNaturalist requires a short-lived JWT. A signed-in user can copy one from
      https://www.inaturalist.org/users/api_token
  It is valid for ~24 h, after which a fresh token must be pasted into the
  plugin settings. (iNaturalist asks that the vision API not be used for heavy
  automated/bulk workloads — this plugin is one photo per manual invocation.)

Returns normalised suggestions:
  { { scientificName=, commonName=, score=0..1, source='iNaturalist',
      iconic=, rank= }, ... }
------------------------------------------------------------------------------]]

local LrHttp = import 'LrHttp'
local json = require 'json'

local iNaturalistAPI = {}

-- jpegFilePath: path to a JPEG on disk.
-- token:        the JWT copied from the api_token page.
-- lat, lng:     optional numbers (photo GPS) to improve ranking.
function iNaturalistAPI.identify(jpegFilePath, token, lat, lng)

	if not token or token == '' then
		return nil, 'No iNaturalist API token configured.'
	end

	local url = 'https://api.inaturalist.org/v1/computervision/score_image'

	local content = {
		{
			name = 'image',
			fileName = 'photo.jpg',
			filePath = jpegFilePath,
			contentType = 'image/jpeg',
		},
	}

	if type(lat) == 'number' and type(lng) == 'number' then
		table.insert(content, { name = 'lat', value = string.format('%.6f', lat) })
		table.insert(content, { name = 'lng', value = string.format('%.6f', lng) })
	end

	local headers = {
		{ field = 'Authorization', value = 'Bearer ' .. token },
		{ field = 'Accept', value = 'application/json' },
	}

	-- LrHttp.postMultipart( url, content, requestHeaders, timeout, ... )
	local body, respHeaders = LrHttp.postMultipart(url, content, headers, 30, nil, false)

	if not body then
		local status = respHeaders and respHeaders.error and respHeaders.error.name or 'unknown'
		return nil, 'iNaturalist request failed (' .. tostring(status) .. ').'
	end

	local ok, parsed = pcall(json.decode, body)
	if not ok or type(parsed) ~= 'table' then
		return nil, 'Could not parse iNaturalist response.'
	end

	-- Auth / quota errors come back as a JSON object with `error` / `status`.
	if parsed.error or (parsed.status and tonumber(parsed.status) and tonumber(parsed.status) >= 400) then
		local msg = parsed.error or ('HTTP ' .. tostring(parsed.status))
		if tostring(msg):find('401') or tostring(parsed.status or '') == '401' then
			msg = 'token rejected — paste a fresh one from inaturalist.org/users/api_token'
		end
		return nil, 'iNaturalist error: ' .. tostring(msg)
	end

	if type(parsed.results) ~= 'table' then
		return {}, nil
	end

	local suggestions = {}
	for _, r in ipairs(parsed.results) do
		local t = r.taxon or {}
		-- combined_score is 0..100; fall back to vision_score if absent.
		local raw = tonumber(r.combined_score) or tonumber(r.vision_score) or 0
		table.insert(suggestions, {
			scientificName = t.name or '',
			commonName = t.preferred_common_name or '',
			iconic = t.iconic_taxon_name or '',
			rank = t.rank or '',
			score = raw / 100,
			source = 'iNaturalist',
		})
	end

	return suggestions, nil
end

return iNaturalistAPI
