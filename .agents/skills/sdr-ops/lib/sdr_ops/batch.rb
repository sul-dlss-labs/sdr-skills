# frozen_string_literal: true

module SdrOps
  # Runs a block per druid with per-item error capture, --limit, and a stop after
  # --max-failures consecutive errors. Skipped items (failed preconditions) don't count as failures.
  class Batch
    DRUID_COLUMNS = %w[druid druid_bare_ssi id].freeze

    def initialize(context)
      @context = context
    end

    def run(input, &block)
      raise UsageError, 'Batch needs a block' unless block

      rows = self.class.read(input)
      rows = rows.first(@context.limit) if @context.limit
      counts = Hash.new(0)
      consecutive = 0
      rows.each do |row|
        outcome = run_one(row, &block)
        counts[outcome] += 1
        consecutive = outcome == 'error' ? consecutive + 1 : 0
        next unless consecutive >= @context.max_failures

        @context.output.warn("Stopping after #{consecutive} consecutive errors (--max-failures #{@context.max_failures})")
        counts['aborted'] = 1
        break
      end
      summary = { batch: { total: rows.size, **counts.transform_keys(&:to_sym) }, dry_run: @context.dry_run?,
                  ledger: @context.ledger.path }
      @context.output.emit(summary)
      @context.output.info('DRY RUN: nothing was changed. Re-run with --execute to apply.') if @context.dry_run?
      summary
    end

    # Accepts a CSV with a druid column (druid, Druid, druid_bare_ssi, or id), a text file with one druid per
    # line, an array of druids, or an array of row hashes. Returns row hashes with a normalized 'druid'.
    def self.read(input)
      rows = case input
             when Array then input.map { |item| item.is_a?(Hash) ? item.transform_keys(&:to_s) : { 'druid' => item } }
             when String then read_file(input)
             else raise UsageError, "Can't read druids from #{input.inspect}"
             end
      rows.map { |row| row.merge('druid' => Druid.normalize(row['druid'])) }
    end

    def self.read_file(path)
      raise UsageError, "No such file: #{path}" unless File.file?(path)
      return read_csv(path) if File.extname(path).casecmp?('.csv')

      File.readlines(path, chomp: true).map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
          .map { |druid| { 'druid' => druid } }
    end

    def self.read_csv(path)
      table = CSV.read(path, headers: true)
      column = table.headers.compact.find { |header| DRUID_COLUMNS.include?(header.strip.downcase) }
      raise UsageError, "#{path} has no druid column (expected one of #{DRUID_COLUMNS.join(', ')})" unless column

      table.filter_map do |row|
        next if row[column].to_s.strip.empty?

        row.to_h.reject { |key, value| key.nil? || value.nil? }.transform_keys(&:strip).merge('druid' => row[column])
      end
    end

    private

    def run_one(row)
      druid = row.fetch('druid')
      @context.forget(druid)
      yield row, @context
      'ok'
    rescue OpenVersionExists => e
      item_result(druid, 'stopped', e)
    rescue Skip => e
      item_result(druid, 'skipped', e)
    rescue AuthError, UsageError, RemoteError
      raise
    rescue StandardError => e
      item_result(druid, 'error', e)
    end

    def item_result(druid, result, error)
      @context.ledger.record(druid:, action: 'item', result:, dry_run: @context.dry_run?, message: error.message)
      @context.output.emit({ druid:, result:, message: error.message, error: error.class.name })
      result
    end
  end
end
