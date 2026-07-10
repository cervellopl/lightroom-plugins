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

This plugin uses **ImgBB** for that step, uploading the rendered JPEG with a
short `expiration` so ImgBB auto-deletes it minutes later (Instagram only reads
it once, during publishing). Your photo is briefly public on ImgBB while it
publishes — if that isn't acceptable, don't use this plugin as-is.

## Requirements

- An Instagram **professional account** (Business *or* Creator).
- That account **linked to a Facebook Page**.
- A **Meta app** with the Instagram Graph API — its **App ID + App Secret**, and
  an access token carrying `instagram_basic`, `instagram_content_publish` and
  `pages_show_list` (the plugin makes it long-lived and keeps it refreshed).
- The **Instagram Business Account ID** (not the Facebook Page ID).
- A free **ImgBB API key**.

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
3. Copy your **App ID** and **App Secret** from **Meta app ▸ Settings ▸ Basic**
   and paste them into the plugin. (These let the plugin keep the token alive —
   see *Never-expiring token* below.)
4. In the **Graph API Explorer** generate a **User access token** with the
   `instagram_basic`, `instagram_content_publish`, and `pages_show_list`
   permissions, and paste it into **Access token**. It's fine that this token is
   short-lived — the next step upgrades it.
5. Click **Get long-lived token**. The plugin exchanges it for a ~60-day token
   and records its expiry (the **Token** line shows the days remaining).
6. Click **Find my account id** — the plugin walks your Facebook Pages, finds the
   linked Instagram account, and fills in the correct id (if you manage several,
   it asks which one). Then **Verify connection** should report
   `Connected as @yourname`.

> **The account id is NOT your Facebook id.** The *Instagram Business Account id*
> is a ~17-digit number starting with `17841…`. If you paste a Facebook user or
> Page id instead, verification fails with `(#12) … username field is
> deprecated`. Use **Find my account id** to get the right one, or query it
> manually: `me/accounts` → your Page → `?fields=instagram_business_account`.

### Never-expiring token

Facebook long-lived tokens last ~60 days, but a *still-valid* one can be
exchanged for a fresh 60-day token any time. With the **App ID + App Secret**
saved, the plugin does this automatically: before every publish (and when you
open the settings) it checks the token's remaining life and, if it's within 10
days of expiring, silently swaps it for a new 60-day token. So as long as you
publish — or just open the Plug-in Manager — at least once every ~2 months, the
connection never expires and you never have to paste a token again.

If you ever let it lapse completely, generate a new Explorer token, paste it, and
click **Get long-lived token** again.

### ImgBB API key

1. Go to <https://api.imgbb.com/> and sign in (free account).
2. Click **Get API key** and copy it.
3. Paste the **API key** into the plugin.

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
- The token, account id and ImgBB API key are stored in Lightroom's plugin
  preferences on this machine.

## File overview

| File | Purpose |
|------|---------|
| `Info.lua` | Plugin manifest / publish-service registration |
| `InstagramPublishServiceProvider.lua` | The Publish Service: dialog, collection behaviour, `processRenderedPhotos` (host → container → publish) |
| `InstagramAPI.lua` | Instagram Graph API wrapper (containers, publish, status, account discovery) |
| `InstagramAuth.lua` | Long-lived token exchange + automatic refresh (never expires) |
| `ImageHost.lua` | Uploads the JPEG to ImgBB to obtain a public URL |
| `PluginInfoProvider.lua` | Plug-in Manager panel (token, account id, ImgBB) |
| `json.lua` | JSON encode/decode (rxi, MIT) |
