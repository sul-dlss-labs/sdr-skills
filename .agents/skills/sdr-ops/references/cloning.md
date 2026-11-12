# Cloning objects for testing

`clone` recreates an item from another environment (default prod) in stage or qa, as it is now. Use it to rehearse a remediation on a faithful copy before touching the real object.

```
sdr-ops --env stage --run DIR clone DRUID --apo rz685py5647 [--from prod] [--source public|dsa]
        [--collection DRUID] [--tag TAG] [--skip-unavailable] [--keep-open] [--execute]
```

## What gets copied

- **Type, object access, description, and geographic metadata.**
  - The description is copied without its `purl`; DSA assigns the clone's.
  - The clone gets a new source ID, `sdr-ops:clone-<druid>-<timestamp>`.
  - It's tagged `sdr-ops : clone of <env> <druid>` (plus `Registered By` and any `--tag`).
  - It isn't in any collection unless you pass `--collection`, because source collections usually don't exist in the target.
- **Structural metadata:** the same file sets (order, labels, types) and the same per-file attributes (mimetype, use, preserve/shelve/publish, access, sdrGeneratedText, presentation, …). Only identifiers and versions are new. It's written in a single cocina update.
- **Bytes:** every file is downloaded from the source and checked against its size, md5, and sha1, then staged in the target workspace.
  - World-downloadable shelved files come from the source's **stacks**.
  - Other preserved files come from the source's **preservation**, through a workspace host (`--host`) with the robot app's preservation client. That needs ssh to the source environment's workspace host, but no source DSA token.
  - Files that are neither (unpreserved, not world-downloadable) can't be fetched. The clone stops unless `--skip-unavailable` leaves them out.

Version 1 is then closed, which runs accessionWF only: no assembly or GIS robots touch the clone. `--keep-open` leaves version 1 open, so more changes can go in with the same `--run` before accessioning.

## Where the source cocina comes from

- `--source public` (default) uses the source environment's purl JSON, i.e. the last published version. It needs no source login, but dark or unpublished objects aren't there, and neither are files with `publish: false`.
- `--source dsa` uses the source's DSA head version, including unpublished files and an open version's changes. It needs `sdr-ops --env <source> login`. Bytes come from the latest preserved and published copies, so files changed in an open version fail their checksum check.

## Notes

- `--env prod` is refused: clones are for testing.
- Downloads are kept in `<run>/downloads/<source druid>/` and reused on a re-run if they still match.
- A dry run fetches the source cocina, which is a read, and validates the registration, but downloads and creates nothing.
- Nothing is created until every download has been checked.
