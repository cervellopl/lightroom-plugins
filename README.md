# Plant & Mushroom Tagger — Lightroom Classic plugin

Identify the plant or mushroom in the selected photo using **Pl@ntNet** and
**iNaturalist**, pick the correct name from a ranked suggestion list, and write
it into the photo's metadata (keyword, custom fields, and/or caption).

## What it does

1. You select a photo in the Lightroom Classic **Library**.
2. Run **Library ▸ Plug-in Extras ▸ Identify Plant / Mushroom…**
3. The plugin renders a JPEG of the photo and sends it to:
   - **Pl@ntNet** — species identification for **plants** (returns scientific +
     common names with a confidence score).
   - **iNaturalist** computer vision — covers **plants *and* fungi**, returns the
     scientific name, preferred common name, and a confidence score. If the
     photo has GPS metadata, its coordinates are sent to improve the ranking.
4. Suggestions from both are merged, de-duplicated, and ranked by confidence.
5. You pick one (or edit the text freely) and choose where to write it.

## Install

1. Copy the whole `PlantMushroomTagger.lrdevplugin` folder somewhere permanent
   (e.g. `Documents\Lightroom\Plugins\`).
2. In Lightroom Classic: **File ▸ Plug-in Manager… ▸ Add**, and select the
   `PlantMushroomTagger.lrdevplugin` folder.

## Configure API keys (required)

Open **File ▸ Plug-in Manager ▸ Plant & Mushroom Tagger** and paste your keys.
You can supply either or both — the plugin uses whatever is available.

### Pl@ntNet (free)
1. Sign up at <https://my.plantnet.org/>.
2. Go to your account → **API** and copy your API key.
3. The free tier allows a limited number of identifications per day.

### iNaturalist (free, OAuth — connect once)
1. Create a free account at <https://www.inaturalist.org/> and sign in.
2. Register an application at
   <https://www.inaturalist.org/oauth/applications/new>:
   - **Name:** anything (e.g. "My Lightroom Tagger").
   - **Redirect URI:** `urn:ietf:wg:oauth:2.0:oob`  ← important, enables the
     copy-paste authorization flow used by the plugin.
3. Copy the generated **Client ID** and **Client Secret** into the plugin's
   iNaturalist section.
4. Click **Authorize…**. A browser opens; sign in and approve, then paste the
   authorization code iNaturalist shows back into the plugin dialog.

That's it — the plugin stores the OAuth access token and from then on fetches a
fresh 24 h API token **automatically** before each identification (renewing the
access token silently if it is ever rejected). No manual token juggling.

> **Manual token (fallback):** if you don't want to register an app, you can
> instead paste a 24 h token from <https://www.inaturalist.org/users/api_token>
> into the *Manual token* field — but you'll need to replace it daily.
>
> iNaturalist asks that the vision API not be used for heavy automated/bulk
> workloads — this plugin only scores one photo per manual run.

## Where the tag is written

In the picker dialog you choose any combination of:

- **Keyword** — added as a Lightroom keyword (searchable, exportable to IPTC).
- **Custom metadata fields** — *Scientific Name*, *Common Name*, *ID Source*,
  *ID Confidence*, visible in the Library Metadata panel and searchable.
- **Caption** — the standard IPTC caption/description field.

Your last choice is remembered as the default.

## Notes & limitations

- **Mushrooms:** Pl@ntNet only identifies plants; fungi are covered by
  iNaturalist, which returns proper species names and an iconic-taxon flag
  (Plantae / Fungi). Still verify — vision suggestions are not identifications.
- **File formats:** works with **any format Lightroom can read** — RAW
  (CR2/CR3, NEF, ARW, RAF, ORF, DNG…), **HEIC**, TIFF, PNG, JPEG. The plugin
  never reads the original file; it asks Lightroom to render the photo to a
  ~1600 px sRGB JPEG (a real export), so format support equals Lightroom's own.
  Note HEIC also needs the OS HEIF codec that Lightroom itself relies on.
- If the export can't render (rare), it falls back to Lightroom's cached
  preview. Make sure the plant/mushroom fills the frame for best results
  (crop first if needed).
- Requires an internet connection. Both requests time out after 30 s.
- Works on one photo at a time (the most-selected photo).

## Menu location & keyboard shortcut

The command appears in **two** places (the Lightroom SDK does **not** allow
plugins to add items to the right-click context menu, so these are the only
options available):

- **Library ▸ Plug-in Extras ▸ Identify Plant / Mushroom...**
- **File ▸ Plug-in Extras ▸ Identify Plant / Mushroom...**

### Keyboard shortcut (Windows)

Lightroom has no SDK for plugin hotkeys, so use the bundled
`LightroomIdentifyShortcut.ahk` ([AutoHotkey v2](https://www.autohotkey.com/)):

1. Install AutoHotkey v2 and double-click the `.ahk` file (a green **H** shows
   in the system tray).
2. In the Library module, select a photo and press **Ctrl + Alt + I**.
3. To auto-start it with Windows, drop a shortcut to the `.ahk` in the
   `shell:startup` folder (Win+R → `shell:startup`).

Edit the top of the `.ahk` to change the hotkey (e.g. `^!i` → something else).

### Keyboard shortcut (macOS)

No extra tool needed: **System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App
Shortcuts ▸ +**, choose Adobe Lightroom, and enter the exact menu title
`Identify Plant / Mushroom...` with your chosen key combo.

## File overview

| File | Purpose |
|------|---------|
| `Info.lua` | Plugin manifest / menu registration |
| `IdentifyPlant.lua` | Main workflow: fetch image → query APIs → pick → write |
| `PlantNetAPI.lua` | Pl@ntNet REST wrapper |
| `iNaturalistAPI.lua` | iNaturalist computer-vision REST wrapper |
| `iNatAuth.lua` | iNaturalist OAuth flow + automatic API-token refresh |
| `PluginInfoProvider.lua` | Settings panel (keys, OAuth, defaults) |
| `MetadataDefinition.lua` | Custom metadata field definitions |
| `json.lua` | JSON decode (rxi, MIT) |

`LightroomIdentifyShortcut.ahk` lives **outside** the `.lrdevplugin` folder — it
is an optional Windows helper, not part of the plugin itself.
