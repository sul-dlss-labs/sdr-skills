# Workflows

Workflow templates live in DSA (`config/workflows/*.xml`). Workflows are served by DSA; workflow-server-rails is obsolete.

## Templates that matter for remediation

- **gisAssemblyWF** (gis-robot-suite):
  - Steps: start-gis-assembly-workflow (fails unless the version is open), register-druid, extract-iso19139-metadata, extract-iso19110-metadata, extract-fgdc-metadata, generate-tag, generate-descriptive, assign-placenames, extract-boundingbox, finish-gis-assembly-workflow, start-derivative-workflow.
  - It needs files in the GIS stage directory (`/gis_workflow_data/stage/…`). The finish step copies stage → workspace and deletes the stage copy. Re-running it for an existing object usually fails unless something (e.g. preassembly) stages the files first.
- **gisDerivativeWF** (gis-robot-suite): start-gis-derivative-workflow (needs an open version), fetch-files, create-derivatives, start-accession-workflow.
  - fetch-files pulls preserved master files that are missing from the workspace.
  - create-derivatives regenerates the derivatives.
  - The last step **closes the version**, which starts accessionWF.
- **accessionWF** (common-accessioning and DSA): start-accession, stage, technical-metadata, shelve, publish, release-initiate/update-doi/update-orcid-work, sdr-ingest-transfer, sdr-ingest-received, reset-workspace, end-accession. It is started by closing a version; `workflow run accessionWF` is refused.
- **No workflow regenerates structural metadata from files on disk.** Structural changes must be made explicitly (see [files.md](files.md)).

## sdr-ops behaviour

- `workflow run WF [--version N] [--lane low|default|high]` creates the workflow for the version (the current one by default; the version is always sent explicitly, because DSA silently treats a missing version as 0).
  - Creating replaces existing steps of that workflow for that version.
  - It refuses `gisAssemblyWF`, `gisDerivativeWF`, and `assemblyWF` unless that version is open.
- `workflow set WF STEP STATUS` sets a step, guarded on the status it read just before (`--expect` overrides that). If the step changed in between, DSA returns a conflict and the item is skipped.
  - Valid statuses: waiting, started, completed, queued, error, skipped, retrying.
- `workflow reset WF STEP` is `set … waiting --expect error`, the same as Argo's workflow-grid reset button. It clears the error and re-queues the step. Robots only pick up `queued`/`retrying` steps for the active version.
- `workflow skip-all WF --note TEXT` skips every step of that workflow for the active version.
- Attribution: `set`, `reset`, and `skip-all` write a note such as `set create-derivatives to waiting by jdoe via sdr-ops; <reason>; <ticket>`. Workflow creation can't carry a note, so only the ledger records who ran it.
- `check --until WF:complete` or `--until WF:STEP:complete` reports, for the current version, whether each druid is `complete`, `pending` (with the current step), or `error` (with the message). It evaluates once and never polls. Re-run it later; accessioning can take minutes to hours.

## Common patterns

- **Regenerate geo derivatives:** `version open --description "Regenerate derivatives"`, then `workflow run gisDerivativeWF`. Don't close it yourself: the workflow closes the version.
- **Resolve a workflow that errored inside someone's open version, without re-running it:** `workflow skip-all gisDerivativeWF --note "…"`, then `version close`. The version keeps its own description. Do this only with the user's agreement.
- **Retry after fixing the cause:** `workflow reset WF STEP`.
