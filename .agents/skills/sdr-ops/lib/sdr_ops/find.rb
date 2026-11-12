# frozen_string_literal: true

module SdrOps
  # Find objects by search facets or workflow state. Runs remote/find.rb on the DSA host (read-only),
  # because DSA's API has no search. See references/discovery.md.
  class Find
    DEFAULT_FIELDS = %w[display_title_ss collection_title_ssimdv bare_member_of_collection_ssm current_version_ipsidv
                        processing_status_text_ssidv wf_error_ssim].freeze
    FIELD_PATTERN = /\A[A-Za-z0-9_]+\z/
    SOURCES = %w[solr workflows].freeze

    def initialize(context)
      @context = context
    end

    # @return [Array<Hash>] rows, each with a bare 'druid'
    def run(source: 'solr', workflow: nil, step: nil, status: nil, error_match: nil, content_type: nil,
            collection: nil, facets: {}, fields: nil)
      params = build_params(source:, workflow:, step:, status:, error_match:, content_type:, collection:, facets:,
                            fields:)
      @context.transport.preflight!(user: DSA_USER, host: @context.environment.dsa_host)
      records = @context.transport.dsa_runner(File.join(REMOTE_DIR, 'find.rb'),
                                              env: { 'SDR_OPS_FIND' => JSON.generate(params) })
      records.reject { |record| record.key?('done') }
    end

    def build_params(source:, workflow:, step:, status:, error_match:, content_type:, collection:, facets:, fields:)
      raise UsageError, "--source must be one of #{SOURCES.join(', ')}" unless SOURCES.include?(source)
      raise UsageError, '--step needs --workflow' if step && !workflow
      raise UsageError, '--status needs --workflow and --step' if status && !(workflow && step)
      raise UsageError, '--source workflows needs --workflow and --step' if source == 'workflows' && !(workflow && step)

      fields = (fields || DEFAULT_FIELDS).map(&:to_s)
      bad = [*fields, *facets.keys].grep_v(FIELD_PATTERN)
      raise UsageError, "Bad Solr field name(s): #{bad.join(', ')}" if bad.any?

      Regexp.new(error_match) if error_match # validate locally
      { source:, workflow:, step:, status:, error_match:, content_type:,
        collection: collection && Druid.normalize(collection), facets:, fields: }
    end

    # The equivalent Argo report CSV download, for people without DSA ssh access.
    def argo_url(workflow: nil, step: nil, status: nil, content_type: nil, collection: nil, facets: {}, fields: nil)
      filters = []
      filters << ['content_type_ssimdv', content_type] if content_type
      filters << ['wf_wps_ssimdv', [workflow, step, status].compact.join(':')] if workflow
      filters << ['member_of_collection_ssim', Druid.normalize(collection)] if collection
      filters.concat(facets.to_a)
      query = filters.map { |field, value| "f%5B#{field}%5D%5B%5D=#{ERB::Util.url_encode(value)}" }
      query << "fields=#{['druid_bare_ssi', *(fields || DEFAULT_FIELDS)].join(',')}"
      "#{@context.environment.argo_url}/report/download?#{query.join('&')}"
    end

    def self.write(rows, out:, format:)
      FileUtils.mkdir_p(File.dirname(File.expand_path(out))) if out
      io = out ? File.open(out, 'w') : $stdout
      if format == 'csv'
        headers = rows.flat_map(&:keys).uniq
        io.puts(CSV.generate_line(headers))
        rows.each { |row| io.puts(CSV.generate_line(headers.map { |h| row[h] })) }
      else
        rows.each { |row| io.puts(JSON.generate(row)) }
      end
    ensure
      io.close if out && io
    end
  end
end
