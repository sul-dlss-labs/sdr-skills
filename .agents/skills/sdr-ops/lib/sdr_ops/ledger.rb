# frozen_string_literal: true

module SdrOps
  # Append-only JSON-lines record of every action in a run (runs/<run>/ledger.jsonl).
  # It also answers "did this run open that version?", which gates content changes.
  class Ledger
    OPENING_ACTIONS = %w[version.open version.adopt object.register].freeze

    attr_reader :path

    def initialize(path:, run_id:, env:, as:)
      @path = path
      @base = { run_id:, env:, as: }
    end

    # @param result [String] ok | planned | skipped | stopped | error
    def record(druid:, action:, result:, dry_run:, args: {}, before: nil, after: nil, message: nil)
      row = { ts: Time.now.utc.iso8601, **@base, druid:, action:, args:, dry_run:, before:, after:, result:, message: }
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, 'a') do |file|
        file.flock(File::LOCK_EX)
        file.puts(JSON.generate(row.compact))
      end
      row
    end

    # @return [Array<Integer>] versions of this druid that this run opened (for real, not in a dry run).
    # Registering an object counts as opening its version 1, and adopting a version counts as opening it.
    def opened_versions(druid)
      rows.filter_map do |row|
        next unless row['druid'] == druid && OPENING_ACTIONS.include?(row['action']) && row['result'] == 'ok'
        next if row['dry_run'] || row['env'] != @base[:env]

        row.dig('after', 'version')&.to_i
      end
    end

    def rows
      return [] unless File.exist?(path)

      File.readlines(path).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
