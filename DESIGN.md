# sdr-ops design

`sdr-ops` is a single agent skill for inspecting and changing objects in the Stanford Digital Repository (SDR). It has three parts:
- a command-line tool and Ruby library that run on the user's laptop, calling the DSA and preservation APIs with short-lived personal tokens;
- a few small scripts that run on SDR servers over ssh, only where a server is genuinely needed;
- reference docs that encode the rules of SDR versioning, workflows, and files.

Task-specific remediation (e.g. for something like [gis-robot-suite#1134](https://github.com/sul-dlss/gis-robot-suite/issues/1134)) has an agent call into `sdr-ops` (see [Worked example](#worked-example-gis-robot-suite1134)).

## Principles

- **Reusable primitives only.** The skill covers operations that recur across remediations: find, inspect, versions, workflows, files, collections. Anything specific to one task lives in a generated script in a run directory.
- **Agent-agnostic.** The skill is plain `SKILL.md` + reference markdown + command-line tools. Nothing depends on a particular agent's tools, so Claude Code, Codex, and others can use it.
- **Laptop-first, using people's existing setups.** Scripting, analysis, and DSA API calls happen on the user's laptop. Servers are reached only over the user's own ssh configuration (`dlss-jump`, Kerberos), and only for four things: minting short-lived tokens, querying the index, moving file bytes, and fetching preserved files. Nothing new is deployed to servers.
- **No long-lived secrets on laptops.** Tokens are personal, expire within hours, live in the OS keychain, and are never printed or written to files.
- **Safe by default.** Mutations are dry runs unless explicitly executed. Preconditions are checked against fresh state, and items that fail them are skipped, never forced.
- **Audit through SDR's own records.** Every change carries a user name and a description, and personal tokens attribute DSA's own events to the person. DSA's events and version history form the audit trail; a local ledger ties a batch together.

## Repository layout

```
sdr-skills/
  .agents/skills/sdr-ops/
    SKILL.md                     # safety rules, prerequisites, command index
    Gemfile  Gemfile.lock        # dor-services-client, cocina-models (+ rspec, rubocop, webmock, jwt for tests)
    bin/sdr-ops                  # entry point (Ruby, runs against the skill's own Gemfile)
    lib/sdr_ops.rb               # library entry point (required by generated scripts)
    lib/sdr_ops/
      cli.rb                     # subcommand parsing
      context.rb                 # env, identity, dry-run/execute, ledger rows
      credentials.rb             # login, keychain storage, expiry checks
      transport.rb               # ssh/scp to servers, preflight
      batch.rb                   # druid list/CSV input, limits, per-item error capture
      object_state.rb            # per-object working copy (cocina + version status), planned changes in dry runs
      ledger.rb  output.rb  shell.rb  druid.rb  environments.rb  errors.rb
      inspect.rb  find.rb  versions.rb  workflows.rb  files.rb  file_sets.rb  collections.rb  registration.rb  cloner.rb  downloads.rb
    remote/                      # the only code that runs on servers
      mint_token.rb              # DSA host: issue a short-lived token
      mint_stacks_token.rb       # stacks host: issue a short-lived stacks service token (optional)
      find.rb                    # DSA host: read-only Solr / workflow-table queries
      fetch_preserved.rb         # workspace host: read-only preservation download
    references/
      environments.md            # env → URLs and hosts; VPN, ssh, kinit prerequisites
      versions.md                # open/close/discard rules and side effects
      workflows.md               # templates, which need/close a version, reset semantics
      files.md                   # cocina File fields, where bytes must be, attribute templates
      discovery.md               # Solr fields, workflow table, Argo report URLs
      writing-scripts.md         # how to write a one-off script against the library
    templates/one_off.rb
    spec/                        # rspec, with an in-memory fake of the DSA client
  .claude/skills/sdr-ops/SKILL.md  # pointer to the .agents copy
```

Specs live inside the skill, next to its Gemfile. No `.ruby-version` is pinned, matching sul-dlss repos. Run directories default to `~/sdr-ops-runs/` (`SDR_OPS_RUNS_DIR` overrides it).

The `.agents/skills/` + `.claude/skills/` pointer convention follows [infrastructure-integration-test PR #1058](https://github.com/sul-dlss/infrastructure-integration-test/pull/1058). For use outside this repo, people symlink `.agents/skills/sdr-ops` into their agent's user-level skills directory (e.g. `~/.claude/skills/sdr-ops`). `bin/sdr-ops` resolves its own location and Gemfile, so it works from any install path.

The Gemfile pins cocina-models and dor-services-client to the versions DSA runs. Dependabot keeps them current, and `login` checks for drift (below).

Draft `SKILL.md` frontmatter:

```yaml
name: sdr-ops
description: >-
  Inspect and change objects in the Stanford Digital Repository (SDR): find objects by
  workflow state or search facets, check version and workflow status, open/close/discard
  versions, run or reset workflows, fetch preserved files, add/remove/replace files in
  structural metadata, change collection membership, and register new (e.g. test) objects. Use for remediation work on
  SDR druids, including one-off scripts that operate on batches of objects.
```

## Execution model

### What runs where

Everything runs on the laptop except the following. These are done over ssh/scp as the listed app user:

| Purpose | Hosts (prod / stage / qa) | User | How |
|---|---|---|---|
| Mint a DSA token (`login`) | `dor-services-app-{prod,stage,qa}-a` | `dor_services` | `remote/mint_token.rb` via `bin/rails runner` in `/opt/app/dor_services/dor_services/current`, with `RAILS_ENV=production` as the DSA README does |
| `find` | same | same | `remote/find.rb` via `bin/rails runner`, wrapped in `ActiveRecord::Base.while_preventing_writes` so it cannot write |
| Mint a stacks service token (`login --stacks`), optional | `sul-stacks-prod-a` / `sul-stacks-stage` / stage's | `stacks` | `remote/mint_stacks_token.rb` via `bin/rails runner` in `/opt/app/stacks/stacks/current` |
| Stage file bytes into `/dor/workspace`, pull files from it, `exec` | `common-accessioning-{prod,stage,qa}-a` (default), or `kurma-robots-{prod,stage,qa}-01` with `--host gis` (adds GDAL, Python 3.12, `uv`) | `lyberadmin` | `scp` / `ssh` into the druid's workspace directory, or a per-run scratch directory `/tmp/sdr-ops-<user>-<run_id>/` |
| Preservation file fetch | same as workspace transfers | `lyberadmin` | `remote/fetch_preserved.rb` run with the app's bundle (`bundle exec ruby`, `config/boot`), using the app's already-configured preservation client; writes to the run's scratch directory, then `scp` back |

DSA API calls go from the laptop to DSA's load balancers (`https://dor-services-{prod,stage,qa}-lb.stanford.edu`), so the laptop must be on the Stanford VPN.

Preservation downloads can't go from the laptop:
- Prod preservation catalog only accepts API calls from SDR servers; from a laptop, requests never reach the app with a bearer token.
- `fetch_preserved.rb` is therefore the one place `sdr-ops` runs inside an app bundle. It is read-only and needs no laptop-side preservation token. It is used in every environment, for one code path.

See [Verification notes](#verification-notes).

### Credentials (`sdr-ops login`)

DSA authenticates with an HS256 JWT. Today's tokens are minted by `bin/rails generate_token` as `{sub: name}` with no expiry ([jwt.rake](https://github.com/sul-dlss/dor-services-app/blob/main/lib/tasks/jwt.rake)). DSA decodes tokens with `JWT.decode(token, secret, true, algorithm: 'HS256')` ([application_controller.rb](https://github.com/sul-dlss/dor-services-app/blob/main/app/controllers/application_controller.rb)). With DSA's jwt 3.2.0, that call rejects a token whose `exp` has passed, so expiring tokens work with no change to DSA's checks.

`sdr-ops login --env ENV [--ttl 8h]`:
1. Checks `klist -s`; if there's no ticket, tells the user to `kinit`.
2. Runs `remote/mint_token.rb` on the DSA host over ssh. It prints `JWT.encode({sub: <sunet>, exp: now + ttl}, Settings.dor.hmac_secret, 'HS256')`, plus DSA's `Cocina::Models::VERSION`.
   - Access to minting is therefore gated by Kerberos + Duo ssh, the same as any server access.
   - The TTL defaults to 8 hours, with a 12-hour maximum.
3. Reads the token from the ssh output inside the `sdr-ops` process and stores it in the OS keychain: macOS `security add-generic-password -s sdr-ops-<env>-dsa -a <sunet>`, or libsecret on Linux. The token is never shown.
4. Compares DSA's cocina-models version with the local bundle's. If they differ, it warns, and mutating commands refuse to run until the bundle is updated.

Other commands load the token from the keychain into the in-process client configuration (`Dor::Services::Client.configure(url:, token:)`). Rules:
- Tokens are never placed in environment variables, run directories, logs, or command output.
- There is no option to display a token.
- An expired or missing token fails fast with "run `sdr-ops login --env ENV`".
- `sdr-ops logout --env ENV` deletes the keychain entry. Otherwise the token simply expires; revocation never requires rotating DSA's shared secret.

A possible follow-up is a small DSA PR so the existing `generate_token` task accepts the name and TTL as arguments and adds `exp`. `login` could then call `bin/rake 'generate_token[<sunet>,8h]'` instead of shipping `mint_token.rb`.

#### Stacks service tokens (`sdr-ops login --stacks`)

Stacks accepts service tokens: HS256 JWTs signed with `Settings.service_token.hmac_secret`, minted by its own `bin/rails generate_token` ([jwt.rake](https://github.com/sul-dlss/stacks/blob/main/lib/tasks/jwt.rake)). It decodes them with `JWT.decode(token, secret, true, algorithm: 'HS256')` (jwt 3.3.0), which enforces `exp`, and gives a service user the same access as a Stanford user ([user.rb](https://github.com/sul-dlss/stacks/blob/main/app/models/user.rb)). Denied service users get a 403 rather than a redirect to the login page.

`login --stacks` mints one the same way as the DSA token. It runs `remote/mint_stacks_token.rb` on the stacks host as `stacks`, and the token gets the same TTL rules, with `{sub: <sunet>, exp: now + ttl, iss: 'sdr-ops'}`. It goes in its own keychain entry (`sdr-ops-<env>-stacks`), and its expiry goes in the state file. It's needed only for `files fetch --source stacks` of Stanford-only files, for example to check derivatives that aren't preserved after accessioning has pruned the workspace. It is sent only to the stacks host, never across a redirect to another host. Stacks counts each fetch as a download in its metrics.

### How a command runs

1. Load the token for `--env` from the keychain and configure the client for that environment's load balancer.
2. Read fresh state from DSA, build the plan, and print it (dry run). With `--execute`, apply it.
3. For file bytes, the sequence is:
   - compute size, md5, and sha1 locally (Ruby's `Digest`);
   - `ssh` to create the druid's workspace `content/` directory if needed;
   - `scp -s` the bytes as `lyberadmin` to a `.sdr-ops-partial` file there;
   - verify the md5 on the host with `md5sum`, `chmod 0644` it, then move the file into place;
   - only then update cocina.

   `-s` forces scp's SFTP mode (the default since OpenSSH 9.0; the servers' sshd enables the sftp subsystem), so remote paths are taken literally rather than re-parsed by a remote shell. scp carries the local file's mode across, and a `content:` upload's Tempfile is `0600`; the `chmod` matters because preservation robots read the exported bag as a different user. Before it was added, `transfer-object` failed with "Permission denied" for 154 China 2000 `.cpg` files (gis-robot-suite#1134); `files make-readable` repairs files staged before the fix. The extra ssh calls are cheap with a ControlMaster setup. Only app commands (`bin/rails runner`, `bundle exec ruby`) use a login shell.
4. Emit JSON lines and append ledger rows.

### Preflight

- **VPN/network:** an unauthenticated `GET /v1/objects/<any druid>` to the environment's DSA load balancer must return DSA's JSON 401. Don't probe `/about`: it returns 502 through the load balancers.
- **Token:** present and unexpired. Expiry is read locally from the token's `exp` claim.
- **Before any server touchpoint:** `klist -s` and `ssh -o BatchMode=yes <user>@<host> true`. A ControlMaster setup, per the DeveloperPlaybook ssh docs, is recommended so batches don't re-authenticate for every file.

### Output

Every command emits JSON lines (one object per druid or per action), so agents can parse results. `--format csv` is available for discovery and reports.

## Guardrails

These are enforced in code, not just described in `SKILL.md`:

- **`--env` is required** (`qa`, `stage`, or `prod`); there is no default. Tokens are per environment, so a stage token can't touch prod.
- **Dry run by default.** Every mutating command prints its plan per druid (cocina diff, workflow actions, file bytes to stage). Only `--execute` applies it. In a dry run, calls are composable: each planned change is applied to an in-memory copy, so later calls on the same item see the planned state.
- **Identity.**
  - `--as` defaults to the user's Kerberos principal. It is sent as `opening_user_name` / `user_name` on every DSA call that accepts one.
  - It must match the token's `sub`, so one person can't act under another's name.
- **Reason.** `--reason` is required for mutations, and `--ticket` is optional. Together they form the description recorded on cocina updates and step notes, e.g. `"Add code page file rail.cpg; gis-robot-suite#1134"`.
- **Fresh preconditions.** Version and workflow state is read immediately before each change. If an item fails a precondition, it is skipped with the reason recorded. There is no force option.
- **Own versions only.** Content changes happen only inside a version that `sdr-ops` opened in the current run. An object that already has an open version stops with an error; that version is never reused or closed implicitly (see [Version handling for content changes](#version-handling-for-content-changes)).
- **Side effects need `--execute`.** Besides SDR changes, downloads (`files fetch`, `pull`), uploads (`push`), and `exec` are dry runs without it, which makes "ask before downloading" the same step as any other confirmation.
- **Optimistic locking.** Updates use the cocina lock (ETag) from the preceding fetch, so a concurrent change causes a conflict instead of being overwritten.
- **Batches.** Input is positional druids, a text file of druids, or a CSV with a `druid` column (compatible with Argo report downloads). Items are processed one at a time. `--limit N` supports pilots, and the run stops after `--max-failures` consecutive errors (default 3).
- **Rules the agent follows** (in `SKILL.md`):
  - In prod, show the dry-run output and get the user's explicit OK for each batch before running with `--execute`.
  - Pilot on a few items, and verify them, before running the rest.
  - Use one environment per run.
  - Never try to read, print, or copy tokens or other secrets, whether from the keychain or from host configuration.
  - Don't use `bin/reset-accessioning`.
  - Ask before downloading files to the user's machine.

## Audit trail

SDR already records the important actions, provided user names and descriptions are passed (which `sdr-ops` always does):

| Action | Recorded by DSA |
|---|---|
| Open version | `version_open` event `{who, version, description}`; version description |
| Close version | `version_close` event `{who, version, description}` |
| Any cocina update (files, attributes, collections) | `update` event `{who, description, success, request}` (the full submitted cocina, so new file entries and digests are included); `collection_changed` for membership |
| Accessioning that follows a close | `publishing_complete`, `shelving_complete`, `cleanup-workspace` |
| Step status changes, skip-all | No event. `sdr-ops` writes attribution into the step's `note` field (e.g. `"reset by jdoe via sdr-ops; gis-robot-suite#1134"`) |
| Workflow creation | No event, and the API takes no note |
| Discard version | `version_discard` `{version}`; the endpoint takes no user name |

Personal tokens add attribution on top of this:
- DSA adds `invoked_by` (the token's `sub`) and `host` to every event it creates ([event_factory.rb](https://github.com/sul-dlss/dor-services-app/blob/main/app/services/event_factory.rb)). Each of the events above therefore names the person who ran `sdr-ops`, not a shared service account.
- That includes `version_discard`, which otherwise carries only the version number.
- DSA also tags errors in Honeybadger with `invoked_by`.

`sdr-ops` creates no events of its own. Batch-level correlation comes from:
- the ticket reference in each description;
- the local ledger (`runs/<run>/ledger.jsonl`), one row per action: `ts, run_id, env, as, druid, action, args, dry_run, before {version, open, description}, after, result (ok|skipped|error), message`. The ledger can be attached to the ticket when a run finishes.

## Commands

### Global options and inputs

```
sdr-ops --env <qa|stage|prod> [--host accession|gis] [--execute]
        [--as SUNETID] [--reason TEXT] [--ticket REF] [--run DIR]
        [--limit N] [--max-failures N] [--format jsonl|csv]
        <command> [DRUID... | --druids FILE] [options]
```

- `--host` chooses the server for workspace transfers and `exec`; `login` and `find` always use the DSA host.
- `--run DIR` sets the run directory, which holds the ledger, outputs, and downloads. It defaults to `<SDR_OPS_RUNS_DIR or ~/sdr-ops-runs>/<date>-adhoc/`. Because the ledger is how a run recognizes versions it opened, related commands must share a `--run`.

### Session

| Command | Behaviour |
|---|---|
| `login [--ttl DURATION]` | Mints and stores a short-lived personal token for `--env` (see [Credentials](#credentials-sdr-ops-login)). |
| `logout` | Deletes the stored token for `--env`. |
| `whoami` | Shows the token's `sub` and expiry (never the token), and the local and DSA cocina-models versions. |

### Inspect (read-only)

| Command | Returns |
|---|---|
| `status` | Current version; version status (`open`, `openable`, `assembling`, `accessioning`, `closeable`, `discardable`, `versionDescription`); who opened an open version (from its `version_open` event); workflows with errors for the current version; collections. Uses batched calls (`objects.statuses`, `find_all`). |
| `show [--version N]` | Cocina JSON. |
| `files [--workspace]` | One row per file: file set, filename, mimetype, use, preserve/shelve/publish, access, size, md5. `--workspace` also checks over ssh whether the bytes are in the druid's workspace. |
| `workflows [--workflow WF] [--version N]` | Step name, status, timestamps, attempts, lane, note, error message. |
| `events [--type T]` | DSA events. |

### Find (read-only, runs on the DSA host)

```
sdr-ops --env prod find [--source solr|workflows]
        [--workflow WF --step STEP --status STATUS] [--error-match REGEX]
        [--content-type TYPE] [--collection DRUID] [--facet FIELD=VALUE ...]
        [--fields F1,F2,...] [--out FILE]
```

DSA's API has no search by workflow state or facet, so `find` runs `remote/find.rb` on the DSA host and streams the results back to the laptop.
- **`--source solr`** (default): the index Argo uses, so results match Argo's report view and workflow grid.
  - Filters use Argo's facet fields, e.g. `content_type_ssimdv`, `wf_wps_ssimdv` (`gisDerivativeWF:create-derivatives:error`), and `member_of_collection_ssim`.
  - Columns use Argo's report field names, e.g. `druid_bare_ssi`, `display_title_ss`, `collection_title_ssimdv`, `bare_member_of_collection_ssm`, `current_version_ipsidv`, `wf_error_ssim`.
  - Queries go through DSA's existing `SolrService`.
- **`--source workflows`**: the workflow table (`WorkflowStep.where(workflow:, process:, status:, active_version: true)`).
  - It is authoritative and has no index lag.
  - It returns full error text; Solr's copy is truncated at about 32 KB.
  - `--error-match` filters on that text, which Argo's facets can't do.
  - Title and collection are added with one batched Solr lookup.
- Output is CSV or JSONL with columns compatible with Argo's report download, so existing `bin/` scripts that take an Argo CSV still work.
- `find --argo-url` prints the equivalent Argo `report/download` link. This is a fallback for people without DSA ssh access, or for checking results in the UI.

### Versions

| Command | Behaviour |
|---|---|
| `version open --description TEXT` | Refuses if a version is already open, and shows that version's description instead. Refuses if the object isn't openable (e.g. still accessioning). |
| `version close [--description TEXT] [--no-accession] [--user-versions none\|new\|update\|update_if_existing] [--lane low\|default\|high]` | A description, if given, replaces the opening one. Closing starts `accessionWF` unless `--no-accession` is passed. Refuses while the object is assembling. |
| `version discard` | Rolls back the open version. The dry run shows the cocina diff that would be lost (open version vs last closed), and warns that discard cleans up only `accessionWF`, `assemblyWF`, and `versioningWF` steps, leaving e.g. gis workflow steps behind. The agent must get the user's confirmation for each item. |

#### Version handling for content changes

This applies to `files …` and `collection …`:
- `sdr-ops` makes content changes only inside a version it opened itself in the current run, as recorded in the run's ledger.
- `--open "<description>"` is required. The command opens a version with that description and the user's name, makes the change, and closes it (starting accessionWF).
  - `--keep-open` leaves the version open, so later commands in the same run can add more changes to it, or run a workflow in it.
  - `--reason` defaults to the version description.
- If the object already has an open version that this run didn't open, the item **stops with an error**. The error names the version, its description, and who opened it (from the `version_open` event).
  - That version most likely has nothing to do with the change at hand, so it is never used or closed implicitly.
  - Resolving it is a separate, explicit decision: `version close`, `version discard`, or finishing or skipping the workflow running in it.
- This applies to every content type. Regenerating derivatives is not part of version handling; when it's needed, it's a separate step (see [Common patterns](#common-patterns)).
- The `version` and `workflow` commands act on the object's current version whoever opened it, since handling existing versions and workflow state is their purpose. Their dry run shows the open version's description and who opened it.

### Workflows

| Command | Behaviour |
|---|---|
| `workflow run WF [--version N] [--lane L]` | Creates or replaces the workflow for the version (default: current, always passed explicitly). It checks preconditions from `references/workflows.md`. For example, it refuses `gisDerivativeWF`, `gisAssemblyWF`, or `assemblyWF` on a closed version, and refuses `accessionWF`, pointing to `version close` instead. |
| `workflow set WF STEP STATUS [--expect STATUS] [--note TEXT]` | Sets a step's status. `--expect` defaults to the status read just before, so a concurrent change causes a conflict (HTTP 409) rather than an overwrite. A note is always written. |
| `workflow reset WF STEP` | Shorthand for `set … waiting --expect error`, the same as Argo's workflow-grid reset button. |
| `workflow skip-all WF --note TEXT` | Skips all steps of the workflow for the active version. |
| `check --until WF[:STEP]:complete` | Evaluates the condition now and reports each druid as `complete`, `pending` (with the current step), or `error` (with the message). It never sleeps or polls; for long waits, the user re-runs it later, or the agent uses its own scheduling if it has any. |

#### Common patterns

- **Regenerate geo derivatives:** `version open --description "Regenerate derivatives"`, then `workflow run gisDerivativeWF`. The workflow's last step closes the version, which starts accessionWF, so no separate close is needed.
- **Resolve a workflow that errored inside an open version, without re-running it:** `workflow skip-all WF --note "…"`, then `version close`. Closing isn't blocked by an errored gisDerivativeWF, but its error stays on the object (and in Argo) until the steps are skipped or re-run.

### Files

| Command | Behaviour |
|---|---|
| `files fetch [FILENAME...] [--version N] [--source preservation\|workspace\|stacks] [--to DIR]` | Downloads to `--to` (default `<run>/downloads/<druid>/`). **Preservation** (default): `remote/fetch_preserved.rb` on the workspace host calls `Preservation::Client.objects.content_to_file(…, expected_md5:)`, then the file is `scp`'d back and its md5 re-checked locally. **Workspace**: `scp` from the druid's workspace, for files the robots have already staged there. **Stacks**: an HTTP download of shelved files, as users get them. World-downloadable files need no credentials; Stanford-only files are sent with the stacks service token from `login --stacks`. Location-restricted and no-download files are refused. |
| `files add PATH... [--filename NAME] [--like FILENAME \| --file-set ID \| --new-file-set LABEL] [--mimetype T] [--use U] [--preserve/--shelve/--publish BOOL]` | Computes size, md5, and sha1 locally. Copies the bytes into `/dor/workspace/<druid tree>/content/<filename>` over `scp` and verifies the md5 on the host. Builds the cocina File, copying `access`, `administrative`, and `use` from the `--like` sibling, and adds it to the sibling's file set (or the given one). Refuses if the filename already exists (use `replace`). |
| `files replace FILENAME PATH` | Keeps the existing entry's identifier and attributes, stages the new bytes the same way, and updates size and digests. |
| `files remove FILENAME...` | Removes entries from structural metadata. Empty file sets are kept unless `--drop-empty-file-sets` is given. |
| `files set FILENAME [--mimetype] [--use] [--preserve/--shelve/--publish] [--access-from-object]` | Changes attributes, e.g. the `.ovr` mimetype fix. Turning preserve on requires the bytes to be present in the workspace. |
| `files move [FILE...] [--from FILESET]... --to FILESET [--position N] [--drop-empty-file-sets]` | Moves named files and/or whole file sets' contents into a file set (by ID or label) at a position; moving within one file set reorders it. Identifiers and attributes don't change. `--drop-empty-file-sets` removes file sets the move empties. |
| `files make-readable FILENAME... [--no-export]` | Over ssh as `lyberadmin`, `chmod go+r` the files' workspace copies and their copies in the export bag (`/dor/export/<druid>/data/content/`, following symlinks), reporting modes before and after; the dry run only reports. Changes no cocina, so it needs no version. For `transfer-object` "Permission denied" errors, followed by `workflow reset preservationIngestWF transfer-object`. |

### File sets

| Command | Behaviour |
|---|---|
| `filesets DRUID...` | Lists file sets: position, ID, label, type, files. |
| `filesets add --label L [--type T] [--position N]` / `filesets set FILESET [--label L] [--type T]` / `filesets remove FILESET... [--with-files]` / `filesets order FILESET...` | Adds (unique labels), renames/retypes, removes (refusing ones with files unless `--with-files`), and reorders (every file set named once) file sets. Version handling is as for files. With `--druids FILE`, the same operation applies to every object. |

### Collections

| Command | Behaviour |
|---|---|
| `collection add COLLECTION_DRUID` / `collection remove COLLECTION_DRUID` | Updates `structural.isMemberOf`. DSA validates that the collection exists. Version handling is as for files. |

### Registration

| Command | Behaviour |
|---|---|
| `register --title TEXT --apo DRUID [--type object] [--source-id ID] [--collection DRUID] [--tag TAG]... [--view V --download D] [--accession]` | Registers an item the way Argo does: DSA registration with the user's name, a `Registered By : <sunet>` tag (plus any `--tag`), and registrationWF for version 1. `--source-id` defaults to `sdr-ops:<sunet>-<timestamp>`; access defaults to the APO's. The run owns the new object's version 1 (the ledger records the registration), so files can be added before accessioning. `--accession` closes version 1 right away, starting accessionWF. |

### Cloning

| Command | Behaviour |
|---|---|
| `clone DRUID --apo DRUID [--from prod] [--source public\|dsa] [--collection DRUID] [--tag TAG]... [--skip-unavailable] [--keep-open]` | Recreates an item from another environment (default prod) in stage or qa (`--env prod` is refused), for rehearsing remediations. Copies type, object access, description (minus purl), geographic metadata, and structural metadata (file set order/labels/types and every per-file attribute; new identifiers) in one cocina update. Bytes come from source stacks when world-downloadable, otherwise source preservation via a workspace host, each checked against cocina's size, md5, and sha1 before anything is created. `--source public` reads purl (no source login); `dsa` reads the source's head version (needs a login there). Closes version 1 (accessionWF only) unless `--keep-open`. See `references/cloning.md`. |

### Scripts and transfers

| Command | Behaviour |
|---|---|
| `run SCRIPT.rb [ARGS]` | Runs a generated Ruby script locally, with the library and the skill's bundle loaded. Global flags (`--execute`, `--as`, `--reason`, `--limit`, …) reach the script through `SdrOps.context`. Non-Ruby scripts (e.g. Python analysis) just run locally and read or write files in the run directory. |
| `push LOCAL... [--to REMOTE]` / `pull REMOTE... [--to DIR]` | Move files between the laptop and the host (the run's scratch directory by default, or a druid's workspace). |
| `exec -- CMD...` | Escape hatch: runs a shell command in the run's scratch directory on the host, e.g. to process large files in place instead of pulling them. It never touches SDR APIs (it has no token), but the agent shows the command to the user first, as for any prod command. |

### Coverage of PLAN.md

| PLAN.md skill | sdr-ops |
|---|---|
| Add/remove/modify files and update structural metadata | `files add/replace/remove/set/move`, `filesets` |
| Roll back an open version | `version discard` |
| Fetch files from preservation and download them locally | `files fetch` |
| Update the state of a workflow or step | `workflow set/reset/skip-all` |
| Invoke a workflow for one or more objects | `workflow run` (with batch input) |
| Add or remove an object from a collection | `collection add/remove` |
| (not in PLAN.md) Create test objects | `register`, `clone` |
| Reports on files/file types and on descriptive metadata | Separate `sdr-reports` skill later (see below) |

## Library API for generated scripts

A generated script runs locally, requires the library, and works through a batch helper. The helper takes care of druid input, dry-run vs execute, limits, per-item error capture, ledger rows, and attribution:

```ruby
# runs/2026-10-gis-1134/add_cpg.rb
#   sdr-ops --env prod --reason "Add code page file" --ticket gis-robot-suite#1134 \
#     run add_cpg.rb approved.csv [--execute] [--limit 3]
require 'sdr_ops'

SdrOps.batch(ARGV.fetch(0)) do |row, sdr|
  druid = row.fetch('druid')
  # Stops this item if the object already has an open version; closes the new one when the block ends.
  sdr.versions.open(druid, description: 'Add code page file') do
    row.fetch('shapefiles').split(';').each do |base|
      sdr.files.add(druid, filename: "#{base}.cpg", content: row.fetch('cpg_token'),
                           like: "#{base}.dbf", mimetype: 'text/plain')
    end
  end
end
```

The library objects (`sdr.versions`, `sdr.workflows`, `sdr.files`, `sdr.file_sets`, `sdr.collections`, `sdr.registration`, `sdr.cloner`, `sdr.read`, `sdr.find`) expose the same operations, preconditions, and options as the subcommands; the command-line interface is a thin layer over them. Read-only lookups are `sdr.read` rather than `sdr.inspect`, because `inspect` is `Object#inspect`.
- The block form `versions.open(druid, description:) { … }` opens a version for the block and closes it afterwards; `keep_open: true` leaves it open.
- Content changes inside the block are allowed because this run opened that version. Content calls made outside any version the run opened stop the item, just as the commands do.

`references/writing-scripts.md` documents the API and tells the agent where to put generated scripts (the run directory) and how to keep them small.

## Domain rules encoded in the references

These are the facts that make the operations safe to reuse. Each reference doc cites its sources.

**Versions** (`references/versions.md`):
- Opening requires that the object has been accessioned, isn't already open, and isn't accessioning.
- Closing requires an open version that isn't assembling or accessioning.
  - "Assembling" means `gisAssemblyWF` has incomplete steps other than `start-derivative-workflow`, or `assemblyWF` is in progress. `gisDerivativeWF` doesn't count.
- A description given at close replaces the opening one.
- User versions default to `update_if_existing` on the server.
- Discarding requires the head version to be open, not version 1, and the last closed version to have cocina. The open version's cocina is destroyed. Cleanup covers only `accessionWF`, `assemblyWF`, and `versioningWF` steps, plus the workspace and export directories.
- Cocina updates require an open version; otherwise DSA returns a 500.

**Workflows** (`references/workflows.md`):
- Templates live in DSA (`config/workflows/*.xml`).
- `gisAssemblyWF`:
  - It needs an open version and the GIS stage directory (`/gis_workflow_data/stage/...`).
  - Its finish step copies stage → workspace and then deletes the stage copy.
  - Its last step starts `gisDerivativeWF`.
- `gisDerivativeWF`:
  - It needs an open version.
  - `fetch-files` pulls preserved master files that are missing from the workspace.
  - `create-derivatives` regenerates the derivatives.
  - `start-accession-workflow` closes the version, which starts `accessionWF`.
- No workflow regenerates structural metadata from files on disk; structural changes must be made explicitly.
- Creating a workflow replaces existing steps for the same version. An omitted version silently becomes 0, so it is always passed.
- Resetting a step is `update(status: 'waiting', current_status: 'error')`: it clears the error, re-queues the step, and returns 409 if the step is no longer in error. Robots only pick up `queued`/`retrying` steps for the active version.

**Files** (`references/files.md`):
- Required File fields: `externalIdentifier` (`https://cocina.sul.stanford.edu/file/<uuid>`), `label`, `filename`, `type`, `version`, `access`, `administrative {publish, sdrPreserve, shelve}`, and `hasMessageDigests`. An md5 is required in practice whenever the file is shelved.
- Filenames containing `/` are allowed only for `geo` and `object` content types.
- Where the bytes must be:
  - New or changed preserved files must be in `/dor/workspace/<druid tree>/content/` when preservation ingest runs, with digests and size matching cocina.
  - New shelved files must be in the workspace or retrievable from preservation by `publish`.
  - Unchanged files don't need to be present.
- Files are written as `lyberadmin`, the same user the robots run as, so accessioning can read them and `reset-workspace` can prune them at the end.
- Argo's structural CSV import cannot add files.
- Geo conventions:
  - All files are in a single file set.
  - Shapefile sidecars share the `.shp` basename.
  - `.prj`/`.cpg` use `text/plain`.
  - Robot-generated derivatives have `use: derivative` and `sdrGeneratedText: true`.

**Discovery** (`references/discovery.md`):
- Solr field names and value formats:
  - `wf_wps_ssimdv` holds `WF`, `WF:step`, and `WF:step:status`.
  - `wf_error_ssim` holds `WF:step:message`.
- Workflow table columns.
- Argo report and workflow-grid URLs, as a fallback.

## Worked example: gis-robot-suite#1134

Everything lives in `runs/2026-10-gis-1134/`, as generated scripts plus `sdr-ops` calls:

1. **Find affected items:**
   ```
   sdr-ops --env prod login
   sdr-ops --env prod find --source workflows --workflow gisDerivativeWF --step create-derivatives \
     --status error --error-match 'not a valid UTF-8 string' --out items.csv
   sdr-ops --env prod status --druids items.csv > status.jsonl
   ```
   The failing step is in **gisDerivativeWF**, whose last step closes the version, so these items are expected to have an open version. The `status` output confirms this per item.
2. **Detect encodings:** `sdr-ops files fetch --source workspace` pulls the `.dbf` files, which fetch-files already staged in the workspace. A generated `detect_encodings.py` then runs locally against them.
   - The agent proposes an encoding per collection, with decoded samples as evidence, and the user approves them into `approved.csv`.
   - "Decodes without error" is not evidence: the thread's Big5 guess decodes the issue's error bytes into nonsense (傖趵盄), while GBK gives 成渝线, the Chengdu–Chongqing railway.
   - CP1250 garbles Portuguese ã/õ/ê (Acauã → "ACAUĂ"); CP1252, Latin-1, and CP850 are the plausible candidates there.
3. **Resolve the existing open versions.** `add_cpg.rb` would stop on all of these items, so the user first decides what to do with the versions they're stuck in. The `status` output shows each version's description and who opened it.
   - Typically: `workflow skip-all gisDerivativeWF --note "…"`, then `version close`, which keeps those versions' own descriptions.
   - `version discard` is the alternative if their changes aren't wanted.
4. **Add the `.cpg` files** with `add_cpg.rb` (above), which opens and closes its own "Add code page file" version for each item:
   - dry run first;
   - then `--execute --limit 3` as a pilot covering different encodings;
   - then the rest.
5. **Regenerate derivatives only if needed.** The pilot's spot-check (step 7) shows whether the existing `.fgb`/`.pmtiles` derivatives have correct attribute text; they were generated while the `.dbf` declared no encoding. If the text is wrong, those items get the "Regenerate derivatives" pattern.
6. **Confirm:** run `sdr-ops check --druids approved.csv --until accessionWF:complete` later.
   - It also checks `purl.stanford.edu/<druid>.json` for the new version and the `.cpg`.
7. **Spot-check:** for one or two items per encoding, run `sdr-ops files fetch`, then `ogrinfo -al -q` on the `.shp` and the `.fgb`, then open the files in QGIS (and ideally ArcGIS).
   - The `.cpg` values (e.g. `1252` vs `CP1252`, `936` vs `GBK`) must be confirmed as recognized by both GDAL/QGIS and ArcGIS before the pilot.

## Later: sdr-reports

Corpus-wide reports, on file occurrence and file types and on descriptive metadata characteristics, are a separate read-only skill:
- **Where it runs:** on `sdr-infra`, whose read-only DSA database access is documented in the DSA README.
- **What it queries:** `repository_object_versions` stores `structural`, `description`, `access`, and other cocina sections as `jsonb`, so reports are SQL (or `bin/rails runner` scripts) over those columns.
- **Precedents:** DSA's `app/reports/` and cocina-models' `cocina-jq-query` skill.

## Build order and testing

1. `login`/`logout`/`whoami`, transport and preflight, and the inspect commands, tested on stage.
2. `find` (both sources).
3. Versions and workflows.
4. Files (`fetch`, then `add/replace/remove/set`).
5. `run`/`push`/`pull`/`exec`, and the ledger.
6. Collections.
7. The `sdr-reports` skill.

Testing:
- **Unit tests:** rspec for `lib/` with stubbed `Dor::Services::Client` and `Preservation::Client`, in the style of gis-robot-suite's specs.
- **End-to-end:** full flows on stage against throwaway objects; infrastructure-integration-test can create them. Never test against prod.

## Implementation notes

Build-order steps 1–6 are implemented in `.agents/skills/sdr-ops` (2026-11-12); `sdr-reports` is not.
- **Tested:** 83 specs against an in-memory fake of the DSA client and fake ssh. They cover dry-run composability, the own-version rule, attribution, transfers and md5 checks, token handling (never printed or passed as an argument), and the three remote scripts loaded with stand-ins for their server-side constants. rubocop is clean.
- **Not yet run against a real environment.** The first real check is `sdr-ops --env stage login`, then read-only commands (`whoami`, `status`, `find`), then a dry run and an execute of a content change on a throwaway stage object.
- **Small departures from the design above:**
  - digests come from Ruby's `Digest`, not `Assembly::ObjectFile`;
  - read-only lookups are `sdr.read`;
  - no `.ruby-version`;
  - specs live in the skill directory.
- **cocina-models needs `cocina_display` loaded:** its description language validator uses it without requiring it, and the gem depends on it without a version constraint (Bundler picked 0.2.0). The Gemfile pins `cocina_display ~> 2.14` (DSA's version) and `sdr_ops.rb` requires it.
- **dor-services-client 15.71 added `version.update_description`**, which changes an open version's description. `sdr-ops` doesn't use it yet; it could offer a way to describe an open version accurately without closing it.

## Open questions

- **Token policy:** are short-lived personal prod DSA tokens on laptops acceptable to the team and ops, and with what maximum TTL?
  - For the token's lifetime it has full prod write access and sits where agent-run processes could, in principle, read it.
  - The keychain prevents accidental exposure, such as printing or logging, but not deliberate reads.
  - Precedent: infrastructure-integration-test keeps laptop DSA tokens, but only for stage and qa, and they never expire.
- **Minting:** keep `remote/mint_token.rb`, or extend DSA's `generate_token` task to take a name and TTL?
- **Access to the DSA host:** `login` and `find` need ssh access as `dor_services` on `dor-services-app-*-a`. Preflight checks this, but it hasn't been confirmed for everyone who would use `sdr-ops`.
- **Stacks service tokens:** `login --stacks` needs ssh access as `stacks` on the stacks hosts, and a `service_token.hmac_secret` configured in each environment's stacks. Neither has been confirmed yet. Is a personal token with Stanford-level read access acceptable there?
- **Default host for workspace transfers:** is `common-accessioning-<env>-a` acceptable?
- **Workflow creation attribution:** creating a workflow writes no event and takes no note, so only the ledger records who did it.
- **Installation:** confirm the user-level skills directory convention for each agent we support beyond Claude Code, and whether to also publish a Claude Code plugin.
- **Accessioneers without ssh:** out of scope for v1. They couldn't `login` or stage bytes. sdr-api tokens (minted via Argo's `/settings/tokens`) could later cover cocina and file changes, but not workflows.

## Verification notes

Checked on 2026-10-12 from a laptop on the Stanford VPN: all SDR traffic went over a `utun` VPN interface, with no HTTP proxy configured.

- **DSA enforces token expiry.** DSA decodes with `JWT.decode(token, secret, true, algorithm: 'HS256')` using jwt 3.2.0 (its `Gemfile.lock`). Running that exact call against locally minted tokens: one with a past `exp` raised `JWT::ExpiredSignature`, which DSA turns into a 401; one with a future `exp` decoded normally.
- **DSA is reachable from the laptop in all environments.** Unauthenticated `GET /v1/objects/druid:…` against `dor-services-{prod,stage,qa}-lb.stanford.edu` returned DSA's JSON 401 (with Rails `x-request-id` / `x-runtime` headers). `/about` returned 502 on all three load balancers.
  - Not tested: reachability off VPN, which `sdr-ops` doesn't need.
- **Preservation catalog enforces token expiry, but prod isn't reachable from laptops.**
  - Expiry: its `ApiController` decodes with `JWT.decode(token, secret, true, algorithm: 'HS512')` using jwt 3.3.0. The same local test rejected an expired HS512 token.
  - Prod: `GET https://preservation-catalog.stanford.edu/v1/…` from the laptop was redirected to a login page instead of reaching the API.
  - Stage: `preservation-catalog-stage.stanford.edu/v1/…` returned the app's JSON 401.
  - Hence preserved files are fetched via a server in every environment.
- Still unverified: each user's ssh access as `dor_services` on the DSA hosts, which `login` and `find` need. Preflight reports it.

## Key sources

- DSA:
  - authentication and attribution: [`lib/tasks/jwt.rake`](https://github.com/sul-dlss/dor-services-app/blob/main/lib/tasks/jwt.rake), [`app/controllers/application_controller.rb`](https://github.com/sul-dlss/dor-services-app/blob/main/app/controllers/application_controller.rb), [`app/services/event_factory.rb`](https://github.com/sul-dlss/dor-services-app/blob/main/app/services/event_factory.rb)
  - versioning: [`app/services/version_service.rb`](https://github.com/sul-dlss/dor-services-app/blob/main/app/services/version_service.rb), [`app/models/repository_object.rb`](https://github.com/sul-dlss/dor-services-app/blob/main/app/models/repository_object.rb)
  - workflows: [`app/services/workflow/`](https://github.com/sul-dlss/dor-services-app/tree/main/app/services/workflow), [`config/workflows/`](https://github.com/sul-dlss/dor-services-app/tree/main/config/workflows)
  - cleanup: [`app/services/cleanup_service.rb`](https://github.com/sul-dlss/dor-services-app/blob/main/app/services/cleanup_service.rb)
  - accessioning file handling: [`app/services/digital_stacks_differ.rb`](https://github.com/sul-dlss/dor-services-app/blob/main/app/services/digital_stacks_differ.rb), [`app/services/shelvable_files_stager.rb`](https://github.com/sul-dlss/dor-services-app/blob/main/app/services/shelvable_files_stager.rb), [`app/services/preservation_ingest_service.rb`](https://github.com/sul-dlss/dor-services-app/blob/main/app/services/preservation_ingest_service.rb)
  - Solr: [`app/services/solr_service.rb`](https://github.com/sul-dlss/dor-services-app/blob/main/app/services/solr_service.rb)
- [dor-services-client](https://github.com/sul-dlss/dor-services-client) (`lib/dor/services/client/`) and [preservation-client](https://github.com/sul-dlss/preservation-client).
- gis-robot-suite: robots in [`lib/robots/dor_repo/`](https://github.com/sul-dlss/gis-robot-suite/tree/main/lib/robots/dor_repo); remediation precedents in [`bin/`](https://github.com/sul-dlss/gis-robot-suite/tree/main/bin) and [`lib/gis_robot_suite/`](https://github.com/sul-dlss/gis-robot-suite/tree/main/lib/gis_robot_suite) (`ArcgridConverter`, `OvrMimetypeUpdater`, `PreviewJpgRemover`, `StructuralUpdator`, `FileParamBuilder`).
- Argo:
  - reports: [`app/models/report.rb`](https://github.com/sul-dlss/argo/blob/main/app/models/report.rb), [`app/controllers/report_controller.rb`](https://github.com/sul-dlss/argo/blob/main/app/controllers/report_controller.rb)
  - bulk actions: [`app/jobs/`](https://github.com/sul-dlss/argo/tree/main/app/jobs)
  - argo-b3's [`Sdr::VersionService`](https://github.com/sul-dlss/argo-b3/blob/main/app/services/sdr/version_service.rb) and [`Sdr::WorkflowService`](https://github.com/sul-dlss/argo-b3/blob/main/app/services/sdr/workflow_service.rb).
