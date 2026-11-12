# Environments, hosts, and access

`--env` picks one of these. The values live in `lib/sdr_ops/environments.rb`.

| | prod | stage | qa |
|---|---|---|---|
| DSA API (from the laptop) | `https://dor-services-prod-lb.stanford.edu` | `https://dor-services-stage-lb.stanford.edu` | `https://dor-services-qa-lb.stanford.edu` |
| DSA host (`login`, `find`) | `dor-services-app-prod-a` | `dor-services-app-stage-a` | `dor-services-app-qa-a` |
| Workspace host, `--host accession` (default) | `common-accessioning-prod-a` | `common-accessioning-stage-a` | `common-accessioning-qa-a` |
| Workspace host, `--host gis` (GDAL, Python 3.12, `uv`) | `kurma-robots-prod-01` | `kurma-robots-stage-01` | `kurma-robots-qa-01` |
| Purl | `purl.stanford.edu` | `sul-purl-stage.stanford.edu` | stage's |
| Stacks | `stacks.stanford.edu` | `stacks-stage.stanford.edu` | stage's |

All hosts are `*.stanford.edu`. Stage and QA share one `/dor` NFS export; prod has its own.

## What runs where

- **Laptop:** everything else. That includes all DSA API calls (versions, workflows, cocina updates) and scripts run with `sdr-ops run`.
- **DSA host**, as `dor_services`, in `/opt/app/dor_services/dor_services/current` via `bin/rails runner` with `RAILS_ENV=production`:
  - `remote/mint_token.rb` (`login`);
  - `remote/find.rb` (`find`), which is read-only and runs inside ActiveRecord's write prevention.
- **Workspace host**, as `lyberadmin`:
  - file bytes into and out of `/dor/workspace/<druid tree>/content/` (`files add/replace`, `files fetch --source workspace`, `pull workspace:…`);
  - the per-run scratch directory `/tmp/sdr-ops-<sunet>-<run>/` (`push`, `pull`, `exec`).
- **Preserved files** (`files fetch`, default source) also go through the workspace host:
  - `remote/fetch_preserved.rb` runs with the robot app's bundle and its configured preservation client, then the file is copied back.
  - This is needed because prod preservation catalog only accepts API calls from SDR servers.

## Access the user needs

- The Stanford VPN.
- A Kerberos ticket (`kinit`).
- ssh through `dlss-jump` with GSSAPI, per the DeveloperPlaybook ssh configuration. A ControlMaster setup saves re-authenticating for each file.
- ssh access as `dor_services` on the DSA hosts, for `login` and `find`, and as `lyberadmin` on the workspace hosts, for file transfers.

Preflight (`login`, `find`) checks `klist -s` and a non-interactive `ssh … true`, and says which part failed.

## Tokens

- `login` mints `{sub: <sunet>, exp: now + ttl}` signed with DSA's own secret, the same way DSA's `generate_token` does, but with an expiry. DSA's JWT check enforces the expiry.
- Tokens live in the macOS Keychain (service `sdr-ops-<env>-dsa`) or libsecret.
- `~/.config/sdr-ops/<env>.json` holds only non-secret details: subject, expiry, and DSA's cocina-models version at login.
- Because the token's `sub` is the user, DSA records them as `invoked_by` on every event it creates.

## Server-side facts that matter

- Login shells on the robot hosts set `ROBOT_ENVIRONMENT`: usually `production` (even on qa and on common-accessioning stage), but `staging` on `kurma-robots-stage-01`. Never derive it from `--env`. `fetch_preserved.rb` refuses to run without it.
- `/dor/workspace` is pruned at the end of accessioning (`reset-workspace`), so bytes staged for a version are gone once it's accessioned.
