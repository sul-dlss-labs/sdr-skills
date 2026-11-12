# Writing one-off scripts

Task-specific remediation is a small script you generate in the run directory, not a new command in this skill. Ruby scripts run with `sdr-ops run` and use the library; analysis in other languages (e.g. Python over downloaded files) just runs locally and reads and writes files in the run directory.

```
sdr-ops --env stage --run ~/sdr-ops-runs/2026-11-gis-1134 --reason "Add code page file" \
  --ticket gis-robot-suite#1134 run add_cpg.rb approved.csv            # dry run
sdr-ops … run add_cpg.rb approved.csv --execute --limit 3            # pilot
```

Global flags (`--env`, `--execute`, `--limit`, `--reason`, …) can go before or after the script name; other arguments are passed to the script in `ARGV`.

## The API

```ruby
require 'sdr_ops'

# Each row is a Hash with a normalized 'druid' plus any other CSV columns.
# `sdr` is the run's context.
SdrOps.batch(ARGV.fetch(0)) do |row, sdr|
  druid = row.fetch('druid')
  sdr.versions.open(druid, description: 'Add code page file') do |state|
    # Changes here happen in the new version, which closes when the block ends
    # (pass keep_open: true to leave it open). If the block raises, it stays open.
    sdr.files.add(druid, filename: 'rail.cpg', content: '936', like: 'rail.dbf')
  end
end
```

- `SdrOps.batch(input)` handles the input: a CSV or text path, an array of druids, or an array of hashes.
  - It honours `--limit` and stops after `--max-failures` consecutive errors.
  - It records each item as `ok`, `skipped` (raise `SdrOps::Skip, 'why'` to skip one), `stopped` (open version exists), or `error`.
  - It ends with a summary.
- `sdr.versions`: `open(druid, description:, keep_open: false) { |state| … }`, `close(druid, description: nil, accession: true, user_versions: nil, lane: nil)`, `discard(druid)`.
- `sdr.files`:
  - `add(druid, path: | content:, filename:, like:, file_set:, new_file_set:, file_set_type:, mimetype:, use:, preserve:, shelve:, publish:, access_from_object:, access:, sdr_generated_text:)` — `access:` is a file access hash (e.g. `{ view: 'world', download: 'world' }`); `file_set_type:` takes short names (`object`, `preview`, `image`, `file`, …)
  - `replace(druid, filename, path: | content:, mimetype:)`
  - `remove(druid, [filenames], drop_empty_file_sets:)`
  - `set(druid, filename, …)`
  - `fetch(druid, [filenames], source:, version:, to:)`
  - `list(druid, workspace:)`
- `sdr.workflows`: `run(druid, wf, version:, lane:)`, `set(druid, wf, step, status, expect:, note:)`, `reset(druid, wf, step)`, `skip_all(druid, wf, note:)`, `check(druid, 'WF:complete')` (returns a hash).
- `sdr.collections`: `add(druid, collection)`, `remove(druid, collection)`.
- `sdr.registration.register(apo:, title: | description:, geographic:, source_id:, type:, collection:, tags:, view:, download:, accession:)`, where `description:` is a full cocina description hash (e.g. copied from another object, minus `purl`), returns the new druid (nil in a dry run). The run owns the new object's version 1, so `sdr.files.add` can follow before `sdr.versions.close`.
- `sdr.cloner.clone_from(druid, apo:, from: 'prod', source: 'public', collection:, tags:, skip_unavailable:, keep_open:)` returns the clone's druid (stage or qa only).
- `sdr.read` (read-only):
  - `status(druid)`
  - `cocina(druid, version:, public:)` — the cocina as a hash; `public: true` reads purl's copy
  - `public_cocina(druid)`
  - `files(druid)`
  - `workflows(druid, workflow:, version:)`
  - `events(druid, types:)`
- `sdr.find.run(source:, workflow:, step:, status:, error_match:, content_type:, collection:, facets:, fields:)` returns row hashes.
- `sdr.state(druid)` is the working copy: `.cocina` (a Cocina model with lock), `.version`, `.open?`, `.description`, `.own_version?`. `sdr.transport` moves files: `get_file`, `put_file`, `remote_md5`.
- `sdr.output.emit(hash)` prints a result row; `sdr.output.info('…')` prints a message. Use these rather than `puts`, so output stays parseable.
- `sdr.execute?` / `sdr.dry_run?`, `sdr.run_dir`, `sdr.as`.

Every library call follows the same rules as the commands: in a dry run nothing changes, but planned changes are applied to `sdr.state(druid)`, so later calls in the same item see them. Content changes need a version this run opened. Fresh state is read before each change.

## Guidelines

- Keep scripts short: read inputs, call the library, emit rows. Put the decisions (e.g. which encoding each object gets) in an input file the user has reviewed and approved, not in the script.
- Don't call `Dor::Services::Client` directly for anything the library does: you'd bypass dry runs, attribution, and the open-version rule. Reads the library doesn't cover are fine through `sdr.client` (a configured `Dor::Services::Client`).
- Never print or log `sdr.client`'s configuration or any token.
- Start from `templates/one_off.rb`.
