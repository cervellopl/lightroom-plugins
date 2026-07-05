# Instagram Feed Publisher — Lightroom Classic plugin

Publish the selected photo (or a carousel of up to 10) straight to your
**Instagram feed** from Lightroom Classic — review the caption, hit Publish, and
the plugin renders, uploads, and posts through the official **Instagram Graph
API**.

## What it does

1. Select one photo (single post) or several (carousel) in the Library.
2. Run **Library ▸ Plug-in Extras ▸ Publish to Instagram Feed…**
3. Review/edit the caption (pre-filled from the photo's Title/Caption/Headline
   plus your default hashtags).
4. For each photo the plugin:
   - renders a JPEG from Lightroom,
   - uploads it to an image host to get a public URL (see *Why an image host?*),
   - creates an Instagram **media container** referencing that URL,
   - waits for Instagram to finish processing it.
5. The container (or carousel) is **published**, and the resulting permalink is
   written back into the photo's metadata.

## Why an image host? (important)

The Instagram Graph API does **not** accept raw image bytes for feed photos —
you give it a **public `image_url`** and Meta's servers fetch the picture
themselves. So the exported JPEG has to sit at a real URL for a moment.

This plugin uses **Imgur's** free anonymous upload for that step and then
deletes the temporary upload once Instagram has ingested it. Your photo is
briefly public on Imgur during publishing — if that isn't acceptable, don't use
this plugin as-is.

## Requirements

- An Instagram **professional account** (Business *or* Creator).
- That account **linked to a Facebook Page**.
- A **Meta app** with the Instagram Graph API, and a long-lived access token
  carrying `instagram_basic` and `instagram_content_publish`.
- The **Instagram Business Account ID** (not the Facebook Page ID).
- A free **Imgur Client ID**.

## Install

1. Copy the whole `InstagramFeedPublisher.lrdevplugin` folder somewhere
   permanent (e.g. `Documents\Lightroom\Plugins\`).
2. In Lightroom Classic: **File ▸ Plug-in Manager… ▸ Add**, and select the
   `InstagramFeedPublisher.lrdevplugin` folder.

## Configure (required)

Open **File ▸ Plug-in Manager ▸ Instagram Feed Publisher**.

### Instagram Graph API

1. At <https://developers.facebook.com/> create an app (type *Business*) and add
   the **Instagram Graph API** product.
2. Link your Instagram professional account to a Facebook Page you manage.
3. In the **Graph API Explorer** generate a **User access token** with the
   `instagram_basic`, `instagram_content_publish`, and `pages_show_list`
   permissions, then exchange it for a **long-lived** token (≈60 days).
4. Paste the **Access token** into the plugin and click **Find my account id** —
   the plugin walks your Facebook Pages, finds the linked Instagram account, and
   fills in the correct id automatically (if you manage several, it asks which
   one). Then click **Verify connection** — it should report
   `Connected as @yourname`.

> **The account id is NOT your Facebook id.** The *Instagram Business Account id*
> is a ~17-digit number starting with `17841…`. If you paste a Facebook user or
> Page id instead, verification fails with `(#12) … username field is
> deprecated`. Use **Find my account id** to get the right one, or query it
> manually: `me/accounts` → your Page → `?fields=instagram_business_account`.

> Long-lived user tokens expire after ~60 days; re-generate and paste a fresh one
> when publishing starts to fail with an auth error.

### Imgur Client ID

1. Go to <https://api.imgur.com/oauth2/addclient>.
2. Register an application of type **"OAuth 2 without a callback URL"** (that's
   the anonymous-upload flavour).
3. Copy the **Client ID** into the plugin.

### Defaults

- **Exported long edge** — 1080 px (Instagram standard), 1440, or 2048 px.
- **Pre-fill caption from metadata** — use the photo Title/Caption/Headline.
- **Append hashtags** — added to the bottom of every caption.
- **Record permalink** — write the post URL into the photo metadata.

## Image guidelines

Instagram accepts JPEGs with an **aspect ratio between 4:5 (portrait) and 1.91:1
(landscape)**. Crop to those bounds before publishing or the container step will
be rejected. Recommended width is 1080 px. Captions allow up to **2,200
characters** and **30 hashtags**.

## Where results are written

After a successful publish the plugin fills these custom metadata fields
(Library Metadata panel, searchable):

- **Instagram Media ID**
- **Instagram Permalink**
- **Instagram Published At**

For a carousel the same values are written to every photo in the post.

## Menu location & keyboard shortcut

The command appears in **two** places (the Lightroom SDK does **not** allow
plugins to add items to the right-click context menu):

- **Library ▸ Plug-in Extras ▸ Publish to Instagram Feed...**
- **File ▸ Plug-in Extras ▸ Publish to Instagram Feed...**

### Keyboard shortcut (Windows)

Lightroom has no SDK for plugin hotkeys. Use the bundled
`LightroomIdentifyShortcut.ahk` ([AutoHotkey v2](https://www.autohotkey.com/)) as
a template — copy it, point it at the menu title `Publish to Instagram Feed...`,
and bind your own key.

### Keyboard shortcut (macOS)

**System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts ▸ +**, choose
Adobe Lightroom, and enter the exact menu title `Publish to Instagram Feed...`.

## Notes & limitations

- **Feed photos only.** Stories, Reels and video are out of scope.
- **Carousels:** 2–10 photos, published as one post with a shared caption.
- Publishing needs an internet connection; each step times out
  (upload 60 s, container processing up to 2 min).
- Instagram enforces a **content-publishing rate limit** (≈50 posts per 24 h per
  account).
- The token, account id and Imgur Client ID are stored in Lightroom's plugin
  preferences on this machine.

## File overview

| File | Purpose |
|------|---------|
| `Info.lua` | Plugin manifest / menu registration |
| `PublishToInstagram.lua` | Main workflow: render → host → container → publish |
| `InstagramAPI.lua` | Instagram Graph API wrapper (containers, publish, status) |
| `ImageHost.lua` | Uploads the JPEG to Imgur to obtain a public URL |
| `PluginInfoProvider.lua` | Settings panel (token, account id, Imgur, defaults) |
| `MetadataDefinition.lua` | Custom metadata field definitions |
| `json.lua` | JSON encode/decode (rxi, MIT) |
