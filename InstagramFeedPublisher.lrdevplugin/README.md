# Instagram Feed Publisher — Lightroom Classic plugin

A Lightroom Classic **Publish Service** that posts photos to your **Instagram
feed** through the official **Instagram Graph API** — just like the built-in
Flickr publisher. Add photos to the published collection, click **Publish**, and
Lightroom renders and uploads each one for you.

## What it does

1. Set up the **Instagram Feed** publish service once (see *Configure*).
2. In the **Publish Services** panel, drag photos into the **Instagram Feed**
   collection.
3. Click **Publish**. For every photo that needs publishing, Lightroom renders a
   JPEG and the plugin:
   - uploads it to an image host to get a public URL (see *Why an image host?*),
   - creates an Instagram **media container** referencing that URL,
   - waits for Instagram to finish processing it,
   - **publishes** it as a single feed post.
4. Lightroom records the resulting **media id + permalink**, moves the photo to
   *Published*, and marks it *Modified to re-publish* if you later edit the
   title, caption or keywords.

Each photo is posted as its **own single-image feed post**. The caption is taken
from a photo metadata field you choose (Title / Caption / Headline) plus a shared
hashtag template — there is no per-photo prompt, because publishing runs in bulk.

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
   permissions. **This token is short-lived (≈1–2 h) — exchange it for a
   long-lived one (≈60 days)** or the plugin will fail with
   `(code 190) Session has expired`. Exchange it by opening this URL (fill in
   your app id/secret and the short token):
   `https://graph.facebook.com/v21.0/oauth/access_token?grant_type=fb_exchange_token&client_id=APP_ID&client_secret=APP_SECRET&fb_exchange_token=SHORT_TOKEN`
   — the response's `access_token` is the long-lived one to paste in.
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

## Create the publish service

1. In the Library, find **Instagram Feed** in the **Publish Services** panel on
   the left and click **Set Up…** (or right-click ▸ *Edit Settings*).
2. In the service dialog:
   - **Instagram connection** — shows your status; click *Verify connection*.
   - **Caption** — pick which metadata field becomes the caption (Title /
     Caption / Headline / nothing) and enter hashtags to append.
   - **File Settings / Image Sizing** — pre-filled Instagram-ready (JPEG, sRGB,
     fit within 1440 px). Adjust if you like.
3. Click **Save**. An **Instagram Feed** collection appears under the service.

## Publishing

Drag photos into the **Instagram Feed** collection and click **Publish** (top of
the grid). Published photos move to the *Published Photos* group; edit a
published photo's title/caption/keywords and it moves to *Modified Photos to
Re-Publish* — re-publishing creates a **new** post (Instagram has no edit API).

## Image guidelines

Instagram accepts JPEGs with an **aspect ratio between 4:5 (portrait) and 1.91:1
(landscape)**. Crop to those bounds before publishing or the container step will
be rejected. Recommended width is 1080 px. Captions allow up to **2,200
characters** and **30 hashtags**.

## Notes & limitations

- **Feed photos only.** Stories, Reels, video and carousels are out of scope —
  each photo is a single-image post.
- **No per-photo caption prompt.** Publishing is a bulk operation, so captions
  come from the chosen metadata field plus the service's hashtag template.
- **Removing a photo** from the collection only forgets it locally — Instagram's
  Graph API has no endpoint to delete a published post, so the live post stays.
- Publishing needs an internet connection; each step times out
  (upload 60 s, container processing up to 2 min).
- Instagram enforces a **content-publishing rate limit** (≈50 posts per 24 h per
  account).
- The token, account id and Imgur Client ID are stored in Lightroom's plugin
  preferences on this machine.

## File overview

| File | Purpose |
|------|---------|
| `Info.lua` | Plugin manifest / publish-service registration |
| `InstagramPublishServiceProvider.lua` | The Publish Service: dialog, collection behaviour, `processRenderedPhotos` (host → container → publish) |
| `InstagramAPI.lua` | Instagram Graph API wrapper (containers, publish, status, account discovery) |
| `ImageHost.lua` | Uploads the JPEG to Imgur to obtain a public URL |
| `PluginInfoProvider.lua` | Plug-in Manager panel (token, account id, Imgur) |
| `json.lua` | JSON encode/decode (rxi, MIT) |
