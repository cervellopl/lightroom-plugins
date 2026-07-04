# Keyword to Collection

A Lightroom Classic plugin that adds the selected photo(s) to a collection
named after each of their keywords, creating the collection when it does not
already exist.

## Install

1. Copy the `KeywordToCollection.lrdevplugin` folder somewhere permanent.
2. In Lightroom Classic: **File ▸ Plug-in Manager… ▸ Add**, then select the
   `KeywordToCollection.lrdevplugin` folder.

## Use

1. Select one or more photos in the Library grid.
2. **Library ▸ Plug-in Extras ▸ Add to Keyword Collection…**
   (also available under **File ▸ Plug-in Extras**).
3. Choose the options and click **Run**.

For every selected photo, each keyword becomes a collection of the same name.
A photo tagged `Chanterelle` and `Autumn` lands in the `Chanterelle`
collection and the `Autumn` collection; any that don't exist are created.

## Options

- **Also use parent keywords** — walk up the keyword hierarchy so ancestor
  keywords get their own collections too (off by default; only the keywords
  directly applied to the photo are used).
- **Group collections in a set named…** — put every created collection inside
  a single collection set instead of at the top level of the catalog.

## Notes

- Collections are matched/created by name. Two different keywords that share a
  name resolve to the same collection.
- Adding a photo that is already in a collection is a no-op, so the command is
  safe to re-run.
