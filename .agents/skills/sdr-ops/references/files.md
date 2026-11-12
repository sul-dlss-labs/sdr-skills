# Files and structural metadata

## The cocina File

- Required fields: `type`, `externalIdentifier`, `label`, `filename`, `version`, `access`, `administrative {publish, sdrPreserve, shelve}`, and `hasMessageDigests`.
- Optional fields: `size`, `hasMimeType`, `use`, `sdrGeneratedText`.
- An md5 is required in practice whenever a file is shelved.
- `files add` builds new files the way DSA would:
  - The ID is `https://cocina.sul.stanford.edu/file/<druid>-<resource id>/<uuid>`, with the resource ID derived from the file set's ID, as DSA's `Cocina::IdGenerator` does.
  - `label` = filename, and `version` = the open version.
  - Size, md5, and sha1 are computed locally.
  - `sdrGeneratedText: false`.
- Attributes come from a sibling via `--like FILE`: `access`, `administrative`, and `use` are copied, and the new file goes in that sibling's file set.
  - Without `--like`, pass `--preserve`, `--shelve`, and `--publish`. Access is then derived from the object (citation-only becomes dark).
  - Any flag overrides the sibling's value. `--use none` removes the use.
- Mimetype comes from `--mimetype`, or is inferred from the extension. Known extensions:
  - `.cpg`/`.prj`/`.txt` → `text/plain`
  - `.xml` → `application/xml`
  - `.shp` → `application/vnd.shp`
  - `.dbf` → `application/vnd.dbf`
  - `.shx` → `application/vnd.shx`
  - `.tif` → `image/tiff`
  - …

  For anything else, `file --mime-type` is used.
- Filenames containing `/` are allowed only for `geo` and `object` content types. Absolute paths, `..`, newlines, and trailing spaces are refused.

## Where the bytes must be

- New or changed **preserved** files must be in `/dor/workspace/<druid tree>/content/<filename>` when preservation ingest runs, with size and digests matching cocina.
- New **shelved** files must be in the workspace, or retrievable from preservation, when `publish` runs.
- **Unchanged** files don't need to be present.
- `files add` and `replace` copy the bytes to the workspace host as `lyberadmin` (the robots' user), verify the md5 there, and only then update cocina.
  - If identical bytes are already there, the upload is skipped.
  - `add` refuses to overwrite different bytes; `replace` overwrites.
- The workspace is pruned when accessioning finishes.
- Argo's structural CSV import can't add files; this is the supported way.

## Commands

- `files DRUID [--workspace]` lists the files. With `--workspace`, it also checks over ssh whether each one is in the workspace and whether the md5 matches.
- `files add DRUID PATH... --like FILE --open "…"` adds files. `--view`/`--download` set the file's access explicitly, `--sdr-generated true` marks robot-style derivatives, and `--new-file-set LABEL --file-set-type preview` (short names: object, preview, image, file, page, …) creates a file set. In scripts, `content:` (a string) can stand in for a path.
- `files replace DRUID FILE PATH --open "…"` replaces a file's bytes: same identifier and attributes, new size and digests.
- `files remove DRUID FILE... [--drop-empty-file-sets] --open "…"` removes files from structural metadata. Preservation keeps earlier versions' files; the file is absent from the next published version.
- `files set DRUID FILE [--mimetype] [--use] [--preserve] [--shelve] [--publish] [--access-from-object] --open "…"` changes attributes. Turning preserve on requires the bytes in the workspace.
- `files fetch DRUID [FILE...] [--source preservation|workspace|stacks] [--version N] [--to DIR] --execute` downloads files (a dry run without `--execute`). The default destination is `<run>/downloads/<druid>/`, and every download is checked against cocina's md5.
  - `preservation` (default) covers any preserved file in any version; it goes through the workspace host.
  - `workspace` covers files the robots have already staged, e.g. after `fetch-files` ran.
  - `stacks` covers only world-downloadable shelved files. Stacks caches each object's public cocina for 10 minutes, so files from a version published since stacks last served the object can 404 for up to 10 minutes; `files fetch` says so when purl's published version lists the file.

## File sets

File sets (`structural.contains`) are referred to by ID or label; a label matching more than one file set is an error, so `filesets add` refuses duplicate labels. All changes need a version this run opened (`--open`), like other content changes. With `--druids FILE`, leave out DRUID and the same operation applies to every object, which is handy when many objects share a layout.

- `filesets DRUID...` lists position, ID, label, type, and files.
- `files move DRUID [FILE...] [--from FILESET]... --to FILESET [--position N] [--drop-empty-file-sets]` moves files into a file set:
  - named files, and/or every file of each `--from` set, in order;
  - inserted at the 1-based `--position` (default last), so moving within one file set reorders it;
  - files keep their identifiers and attributes;
  - `--drop-empty-file-sets` removes the file sets the move leaves empty.
- `filesets add DRUID --label L [--type T] [--position N]` adds an empty file set. Types: object, file, image, page, preview, document, media, audio, video, attachment, thumb, three_dimensional.
- `filesets set DRUID FILESET [--label L] [--type T]` renames or retypes one.
- `filesets remove DRUID FILESET... [--with-files]` removes file sets. Ones with files are refused unless `--with-files`, which removes those files too.
- `filesets order DRUID FILESET...` reorders; name every file set exactly once.

For example, to collapse a geo object's Data/Preview/Metadata file sets into one:

```
sdr-ops --env stage --run DIR files move DRUID --from Preview --from Metadata --to Data --drop-empty-file-sets \
  --open "Consolidate files into a single file set"
```

## Geo conventions

- A geo object has a single file set (`resources/object`) with every file in it.
- Shapefile sidecars share the `.shp` basename (`rail.shp`, `rail.dbf`, `rail.prj`, `rail.cpg`). GDAL looks for `<basename>.cpg` to learn the `.dbf` encoding.
- Source files: `use: master`, preserved, shelved, published.
- Robot-generated derivatives (`.fgb`, `.pmtiles`, `_cog.tif`, `.jp2`, ISO/FGDC XML) have `use: derivative` (or `thumbnail`) and `sdrGeneratedText: true`. gisDerivativeWF won't overwrite derivatives with `sdrGeneratedText: false`.
