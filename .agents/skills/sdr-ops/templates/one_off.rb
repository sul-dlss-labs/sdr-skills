# frozen_string_literal: true

# <What this script does, and the ticket it's for.>
#
# Input: <describe the CSV columns, e.g. druid, plus whatever decisions the user approved>
# Run (dry run first, then a pilot, then the rest):
#   sdr-ops --env stage --run <run dir> --reason "<what changed>" --ticket <ticket> run <this script> <input.csv>
#   … --execute --limit 2
require 'sdr_ops'

SdrOps.batch(ARGV.fetch(0)) do |row, sdr|
  druid = row.fetch('druid')

  # Skip anything that doesn't need the change, with a reason the user can read.
  # raise SdrOps::Skip, "#{druid}: nothing to do" if ...

  sdr.versions.open(druid, description: '<Version description>') do
    # Content changes go here, e.g.:
    # sdr.files.add(druid, filename: '...', content: row.fetch('...'), like: '...')
  end
end
