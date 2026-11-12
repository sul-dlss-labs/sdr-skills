# frozen_string_literal: true

# Runs on a workspace host with a robot app's bundle (sdr-ops files fetch --source preservation).
# Read-only: downloads preserved files into the run's scratch directory with the app's configured
# preservation client (prod preservation catalog only accepts API calls from SDR servers).
# Input (environment): SDR_OPS_FETCH, JSON {druid, version, dest, files: [{filepath, md5}]}. Output: SDR_OPS_ROW lines.
robot_env = ENV.fetch('ROBOT_ENVIRONMENT', '')
if robot_env.empty? || robot_env == 'development'
  abort 'sdr-ops: ROBOT_ENVIRONMENT is not set by the login profile; refusing to boot with development settings'
end

require 'fileutils'
require 'json'
require File.expand_path('config/boot', Dir.pwd)

request = JSON.parse(ENV.fetch('SDR_OPS_FETCH'))
dest = File.expand_path(request.fetch('dest'))
abort "sdr-ops: destination must be an sdr-ops scratch directory (got #{dest})" unless dest.start_with?('/tmp/sdr-ops-')

Preservation::Client.configure(url: Settings.preservation_catalog.url, token: Settings.preservation_catalog.token)
request.fetch('files').each do |file|
  target = File.expand_path(file.fetch('filepath'), dest)
  abort "sdr-ops: unsafe filepath #{file['filepath'].inspect}" unless target.start_with?("#{dest}/")

  FileUtils.mkdir_p(File.dirname(target))
  Preservation::Client.objects.content_to_file(druid: request.fetch('druid'), filepath: file.fetch('filepath'),
                                               destination_filepath: target, version: request['version'],
                                               expected_md5: file['md5'])
  puts "SDR_OPS_ROW #{JSON.generate(filepath: file['filepath'], path: target, size: File.size(target))}"
end
