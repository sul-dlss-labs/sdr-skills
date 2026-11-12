# Registering objects

`register` creates a new item. It's mostly for throwaway test objects on stage or qa; in prod, treat it like any other change and get the user's OK on the dry run first.

```
sdr-ops --env stage --run DIR register --title "sdr-ops test object" --apo rz685py5647 \
  [--type object] [--source-id ID] [--collection DRUID] [--tag "Project : sdr-ops testing"] \
  [--view world --download world] [--accession] [--execute]
```

What it does:
1. Builds a cocina `RequestDRO`:
   - title and APO, plus an optional collection;
   - the type (default `object`; also `book`, `document`, `file`, `geo`, `image`, `manuscript`, `map`, `media`, `page`, `photograph`, `three_dimensional`, `track`, `webarchive_binary`, `webarchive_seed`);
   - the source ID (default `sdr-ops:<sunet>-<timestamp>`; must be unique in the environment);
   - access, which defaults to the APO's when not given.
2. Registers it with DSA as the user (DSA writes a `registration` event).
3. Adds the `Registered By : <sunet>` tag plus any `--tag`s, as Argo does.
4. Creates registrationWF for version 1.
5. With `--accession`, closes version 1, which starts accessionWF.

The new druid is in the `object.register` row's `druid` field.

**The run owns the new object's version 1**, because the ledger records the registration. So in the same `--run`, files can be added before accessioning, with no `--open`:

```
sdr-ops --env stage --run DIR --execute register --title "Test with files" --apo rz685py5647
sdr-ops --env stage --run DIR --execute files add NEW_DRUID ./sample.txt --new-file-set "Files" --preserve true --shelve true --publish true
sdr-ops --env stage --run DIR --execute version close NEW_DRUID
sdr-ops --env stage --run DIR check --until accessionWF:complete NEW_DRUID
```

On stage, the "Testing APO" is `druid:rz685py5647`. A metadata-only item (no files) accessions in about a minute.
