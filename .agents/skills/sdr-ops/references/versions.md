# Versions

## DSA's rules

- **Open** (`version open --description TEXT`) requires that the object has been accessioned, isn't already open, and isn't accessioning. The description is required and becomes the version's description. `sdr-ops` sends the user as `opening_user_name`.
- **Close** (`version close`) requires an open version that isn't *assembling* or *accessioning*.
  - "Assembling" means `gisAssemblyWF` has incomplete steps (other than `start-derivative-workflow`) or `assemblyWF` is in progress. An errored `gisDerivativeWF` does **not** block closing.
  - Closing starts `accessionWF` unless `--no-accession` is given.
  - A `--description` given at close replaces the opening description.
  - User versions default to `update_if_existing` on the server; `--user-versions none|new|update|update_if_existing` overrides that.
- **Discard** (`version discard`) requires the head version to be open, not version 1, and the last closed version to have cocina.
  - The open version's cocina is destroyed.
  - DSA's cleanup then removes only `accessionWF`, `assemblyWF`, and `versioningWF` steps for that version, plus the workspace and export directories. Other workflows' steps, e.g. gisDerivativeWF, are left behind; the dry run lists them.
  - Discarding is the closest thing to "roll back an open version". Confirm each one with the user.
- **Cocina updates require an open version** (DSA returns a 500 otherwise).

## How sdr-ops handles versions

- Content changes (`files …`, `collection …`) happen only in a version opened **by this run**, as recorded in `<run>/ledger.jsonl`.
  - `--open "<description>"` opens one, makes the change, and closes it.
  - `--keep-open` leaves it open for more changes or a workflow. Later commands with the same `--run` can keep using it.
- If the object already has an open version this run didn't open, the item is `stopped` with that version's number, description, and who opened it (from the `version_open` event).
  - That version is never reused or closed implicitly: it most likely has nothing to do with the change at hand, and may need a different description.
  - What to do about it is the user's decision: `version close` (keeping its description), `version discard`, or finishing or skipping the workflow running in it (see [workflows.md](workflows.md)).
- `version close` and `version discard` act on whatever version is open, whoever opened it. Their output shows its description and who opened it.

## Audit trail

DSA records these on its own, attributed to the user:
- `version_open` and `version_close` events (who, version, description);
- `update` events for every cocina change (who, description, the full submitted cocina);
- `version_discard`.

Because the token's subject is the user, DSA also adds `invoked_by` to each event. `sdr-ops` adds no events of its own; the run ledger ties a batch together.

## Descriptions

Version descriptions should say what changed, e.g. "Add code page file", "Regenerate derivatives", "Remove preview.jpg". The `--reason` (plus `--ticket`) is recorded on each cocina update; it defaults to the version description.
