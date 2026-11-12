# SDR Agent Skills

This is a draft spec for a new repository that will host agent skills used to accession and remediate content in the Stanford Digital Repository.

## Goals

- Assist Stanford-internal users (developers and potentially "accessioneers", i.e. people with Argo access) with modifying content already in SDR
- Leave a clear audit trail of actions taken, in the ways that Stanford systems expect (e.g. meaningful SDR version names)
- Work with users' existing setups (ssh and local agent config, ChatGPT vs Claude, etc.)

## Desired skills

Skills that alter objects should, whenever possible, open a new version with an appropriate description for the given change.

- Add/remove/modify files from an SDR object, and update structural metadata accordingly
- Roll back an object version that is open, e.g. because of an error (similar to existing CLI tool)
- Fetch files from preservation for an object and download them locally
- Update the state of a workflow or step on an object (similar to existing CLI tool)
- Invoke a workflow for a given object or set of objects
- Provide a report on the occurrence of files and file types throughout SDR
- Provide a report on the characteristics of descriptive metadata throughout SDR
- Add or remove an object from a collection

## Initial focus

Remediating [this issue affecting geo items](https://github.com/sul-dlss/gis-robot-suite/issues/1134) by:

- Determining which items are affected by querying workflow status in argo and reading error messages
- For each affected item:
  - Use descriptive metadata and files in stacks/in preservation to guess the encoding
  - Open a new version with a name like "Add code page file"
  - Generate an appropriate .cpg file and add it to the object
  - Close the version and ensure gisAssemblyWF runs to regenerate structural metadata
  - Confirm that the error status clears
  - Confirm that one or two items can be downloaded and look correct (e.g. in QGIS)

## Useful things to draw on / look at

- Existing scripts in [gis-robot-suite /bin](https://github.com/sul-dlss/gis-robot-suite/tree/main/bin) and their associated classes like the [ArcgridConverter](https://github.com/sul-dlss/gis-robot-suite/blob/main/lib/gis_robot_suite/arcgrid_converter.rb), which use `Dor::Services::Client`
- Argo-b3's [`VersionService`](https://github.com/sul-dlss/argo-b3/blob/main/app/services/sdr/version_service.rb) and [`WorkflowService`](https://github.com/sul-dlss/argo-b3/blob/main/app/services/sdr/workflow_service.rb)
- argo's [report view](https://argo.stanford.edu/report?f%5Bcontent_type_ssimdv%5D%5B%5D=geo), including the ability to download a CSV there with the desired set of columns selected
- argo's [workflow grid view](https://argo.stanford.edu/report/workflow_grid?f%5Bcontent_type_ssimdv%5D%5B%5D=geo), which shows how many items are errored at a given step and includes a shortcut "reset" button to retry all of them
