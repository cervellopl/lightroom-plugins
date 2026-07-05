# Keyword to Collection

A Lightroom Classic plugin that adds the selected photo(s) to a collection
named after each of their keywords, creating the collection when it does not
already exist.

## Install

1. Copy the `KeywordToCollection.lrdevplugin` folder somewhere permanent.
2. In Lightroom Classic: **File ▸ Plug-in Manager… ▸ Add**, then select the
   `KeywordToCollection.lrdevplugin` folder.

## Use

1. Select **one or more** photos in the Library grid — the command processes
   the entire selection at once.
2. **Library ▸ Plug-in Extras ▸ Add to Keyword Collection…**
   (also available under **File ▸ Plug-in Extras**).
3. Choose the options and click **Run**.

For every selected photo, each keyword becomes a collection of the same name.
A photo tagged `Chanterelle` and `Autumn` lands in the `Chanterelle`
collection and the `Autumn` collection; any that don't exist are created.
Photos with no keywords are skipped (and counted in the summary).

## Options

**Organize collections as:**

- **Flat** — one collection per keyword name (all at the top level, or inside
  the set below).
- **Mirror keyword hierarchy** — recreate the keyword tree as nested
  *collection sets*, with the keyword itself as a collection inside its parent
  set. Example: keyword `Amanita phalloides` under parent `grzyb` produces a
  collection set `grzyb` containing a collection `Amanita phalloides`.

Other options:

- **Also use parent keywords** *(flat mode only)* — walk up the keyword
  hierarchy so ancestor keywords get their own collections too (off by default).
- **Place everything inside a set named…** — nest all created collections/sets
  under a single top-level collection set instead of the catalog root.

## Notes

- Collections are matched/created by name. Two different keywords that share a
  name resolve to the same collection.
- Adding a photo that is already in a collection is a no-op, so the command is
  safe to re-run.
