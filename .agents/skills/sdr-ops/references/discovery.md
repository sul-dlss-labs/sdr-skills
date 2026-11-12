# Finding objects

DSA's API has no search, so `find` runs `remote/find.rb` on the DSA host (read-only) and streams results back.

```
sdr-ops --env prod find [--source solr|workflows] [--workflow WF --step STEP --status STATUS]
        [--error-match REGEX] [--content-type TYPE] [--collection DRUID] [--facet FIELD=VALUE]
        [--fields F1,F2] [--out FILE.csv]
```

- **`--source solr`** (default) uses the index Argo uses, so results match Argo's report view and workflow grid.
  - Filters are exact term matches on facet fields.
  - `--error-match` is applied to `wf_error_ssim`.
  - At least one filter is required.
- **`--source workflows`** reads DSA's workflow table for active versions (`WorkflowStep.where(workflow:, process:, status:, active_version: true)`).
  - It is authoritative, has no index lag, and has the full error text.
  - It needs `--workflow` and `--step`.
  - Each row adds `version`, `status`, `error_message`, and `updated_at`, plus the requested Solr fields looked up by druid.
- `--out x.csv` writes CSV with a `druid` column, which `--druids x.csv` reads back. Otherwise rows are JSON lines.
- `--argo-url` prints the equivalent Argo report CSV link instead (for people without DSA ssh, or to look at results in Argo).

## Solr fields

| Field | Holds |
|---|---|
| `id` | `druid:…` |
| `druid_bare_ssi` | bare druid |
| `display_title_ss` | title |
| `content_type_ssimdv` | `geo`, `image`, `book`, … |
| `member_of_collection_ssim` | collection druids (`druid:…`) |
| `bare_member_of_collection_ssm` / `collection_title_ssimdv` | collection IDs / titles |
| `current_version_ipsidv` | current version |
| `processing_status_text_ssidv` | status text |
| `wf_wps_ssimdv` | `WF`, `WF:step`, and `WF:step:status` (e.g. `gisDerivativeWF:create-derivatives:error`) |
| `wf_error_ssim` | `WF:step:message`, one per errored step, truncated at about 32 KB |
| `content_file_mimetypes_ssimdv` | mimetypes of the object's files |
| `governed_by_ssim` | APO druid |

The default `--fields` are `display_title_ss collection_title_ssimdv bare_member_of_collection_ssm current_version_ipsidv processing_status_text_ssidv wf_error_ssim`.

## Workflow table columns

`druid, workflow, process, status, error_msg, error_txt, attempts, lifecycle, elapsed, version, note, lane_id, active_version, created_at, updated_at, completed_at`.

## Argo equivalents

- Report CSV: `https://argo.stanford.edu/report/download?f[content_type_ssimdv][]=geo&f[wf_wps_ssimdv][]=WF:step:error&fields=druid_bare_ssi,…`. It needs a browser session.
- Workflow grid: `https://argo.stanford.edu/report/workflow_grid?f[content_type_ssimdv][]=geo` shows counts per step and status.
