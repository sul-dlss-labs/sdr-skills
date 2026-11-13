---
name: sdr-ops
description: >-
  Inspect and change objects in the Stanford Digital Repository (SDR): find objects by
  workflow state or search facets, check version and workflow status, open/close/discard
  versions, run or reset workflows, fetch preserved files, add/remove/replace files in
  structural metadata, change collection membership, register new objects, and clone prod objects into stage or qa for testing. Use for remediation work on
  SDR druids, including one-off scripts that operate on batches of objects.
---

# sdr-ops

A command-line tool (`bin/sdr-ops`, in this skill's directory) and Ruby library for working on SDR objects. It runs on the user's laptop and calls dor-services-app (DSA) with a short-lived personal token. It uses ssh only to mint that token, to search, to move file bytes, and to fetch preserved files.

Run it by its path in this skill's directory, e.g. `<skill-dir>/bin/sdr-ops --env stage status druid:bc641kr2427`. It finds its own Gemfile, so it works from any directory.

## Rules you must follow

1. **Never act on prod without the user's explicit OK for that batch.** Run the command without `--execute` first (a dry run, which changes nothing), show the user the planned actions, and only then re-run with `--execute`.
2. **Pilot first.** For more than a handful of objects, run `--execute --limit 2` or `3`, verify the results (`check`, `status`, `files fetch`), and only then run the rest.
3. **Never read, print, copy, or ask for tokens or other secrets**, from the keychain, `~/.config/sdr-ops`, or any server's configuration. `sdr-ops` handles the token itself; you never need it.
4. **Use one environment per run**, and pass `--env` explicitly every time. Prefer `--env stage` while developing a procedure.
5. **Ask before downloading files** to the user's machine. `files fetch`, `pull`, `push`, and `exec` are dry runs without `--execute`: show the plan first.
6. **Don't work around a stop.** If an item comes back `stopped` (it already has an open version) or `skipped` (a precondition failed), report it to the user. Resolving an open version that someone else opened is the user's decision (see [versions.md](references/versions.md)). Never use DSA's `bin/reset-accessioning`.
7. **Give every run a directory** with `--run`, e.g. `--run ~/sdr-ops-runs/2026-11-gis-1134`, and keep generated scripts and outputs there. The run's ledger is how `sdr-ops` knows which versions it opened.

## Before the first command

- The user must be on the Stanford VPN and have a Kerberos ticket (`kinit`). Their ssh config must reach SDR servers through `dlss-jump` (DeveloperPlaybook ssh setup).
- If `bin/sdr-ops` says gems aren't installed, run `bundle install` in this skill's directory.
- `sdr-ops --env ENV login` mints a token (8 hours by default; `--ttl 4h` for less, 12h maximum). It needs the user to be able to ssh as `dor_services` to the DSA host. `whoami` shows who is logged in and until when.
- `sdr-ops --env ENV login --stacks` mints a separate stacks service token, needed only for `files fetch --source stacks` of Stanford-only files. Like `login`, it's the user's to run.
- If `whoami` or `login` warns about cocina-models drift, the skill's bundle needs updating before any changes can be made. Tell the user; don't work around it.

## Commands

Global options can go anywhere: `--env`, `--execute`, `--run DIR`, `--druids FILE` (CSV with a druid column, or one per line), `--limit N`, `--reason TEXT`, `--ticket REF`, `--as SUNETID`, `--host accession|gis`, `--format jsonl|csv`. `sdr-ops help` lists everything.

| Task | Command | Details |
|---|---|---|
| Who/what/where | `status DRUID...`, `show DRUID [--public]`, `files DRUID [--workspace]`, `workflows DRUID`, `events DRUID` | read-only |
| Find objects | `find --workflow WF --step S --status error [--error-match RE] --out items.csv` | [discovery.md](references/discovery.md) |
| Versions | `version open --description TEXT`, `version close`, `version discard` | [versions.md](references/versions.md) |
| Workflows | `workflow run WF`, `workflow reset WF STEP`, `workflow set WF STEP STATUS`, `workflow skip-all WF --note TEXT`, `check --until WF:complete` | [workflows.md](references/workflows.md) |
| Files | `files fetch`, `files add`, `files replace`, `files remove`, `files set`, `files move`, `files make-readable` | [files.md](references/files.md) |
| File sets | `filesets DRUID`, `filesets add/set/remove/order` | [files.md](references/files.md#file-sets) |
| Collections | `collection add/remove COLLECTION DRUID...` | needs `--open` like files |
| New objects | `register --title TEXT --apo DRUID [--type object] [--accession]` | [registration.md](references/registration.md) |
| Test copies | `clone DRUID --apo DRUID [--from prod]` (into stage or qa) | [cloning.md](references/cloning.md) |
| One-off work | `run SCRIPT.rb ARGS`, plus `push`, `pull`, `exec --` | [writing-scripts.md](references/writing-scripts.md) |

**Content changes** (`files add/replace/remove/set/move`, `filesets add/set/remove/order`, `collection`) happen only in a version this run opened. Pass `--open "Version description"`, and the command opens a version, makes the change, and closes it (which starts accessioning). Add `--keep-open` to keep adding changes to that version or to run a workflow in it. If the object already has an open version that this run didn't open, the item stops and reports who opened it.

## Reading results

Every command prints JSON lines on stdout; messages for people go to stderr.
- Action rows have `druid`, `action`, `result`, `dry_run`, `before`, `after`, and `details`. `result` is `planned` (dry run), `ok`, `skipped`, `stopped`, or `error`.
- Batches end with `{"batch": {...counts...}, "ledger": ...}`.
- Exit codes: 0 means done, though some items may be skipped or stopped; 1 means some items errored; 2 is a usage error; 3 means not logged in or the token expired (run `login`); 4 is an ssh or remote failure.

## Typical procedure

1. `login`, then `find` or take the user's druid list, then `status --druids items.csv` to see the version state of each object.
2. Write any task-specific logic as a small script in the run directory ([writing-scripts.md](references/writing-scripts.md)). Don't add new commands to this skill for one-off work.
3. Dry run, show the user the plan, then pilot with `--execute --limit 2`, then verify.
4. Run the rest. Later, `check --until accessionWF:complete --druids items.csv` to confirm, and share the run's `ledger.jsonl` with the user (e.g. for the ticket).
