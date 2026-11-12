# frozen_string_literal: true

module SdrOps
  # Recreate an item from one environment (default prod) in stage or qa, as it is now, for testing remediations:
  # the same type, access, description, geographic metadata, file sets, per-file attributes, and bytes.
  # See references/cloning.md.
  class Cloner
    SOURCES = %w[public dsa].freeze

    def initialize(context)
      @context = context
    end

    # @param source [String] 'public' (the source environment's purl; no source token needed) or 'dsa' (its DSA head
    #   version, including unpublished files; needs `sdr-ops --env FROM login`)
    # @return [String, nil] the clone's druid (nil in a dry run)
    def clone_from(druid, apo:, from: 'prod', source: 'public', collection: nil, tags: [], skip_unavailable: false,
                   keep_open: false)
      source_env = source_environment!(from)
      raise UsageError, "--source must be one of #{SOURCES.join(', ')}" unless SOURCES.include?(source)

      druid = Druid.normalize(druid)
      cocina = source == 'dsa' ? dsa_cocina(source_env, druid) : public_cocina(source_env, druid)
      raise UsageError, "#{druid} isn't an item; only items can be cloned" unless cocina['structural']&.key?('contains')

      items, unavailable = plan_files(druid, cocina)
      if unavailable.any? && !skip_unavailable
        raise Skip, "#{druid}: can't fetch #{unavailable.join(', ')} (not preserved, and not world-downloadable from " \
                    'stacks); pass --skip-unavailable to leave them out'
      end

      summary = summary(from, source, druid, cocina, items, unavailable)
      registration = registration_args(cocina, from, druid, apo:, collection:, tags:)
      return plan(registration, summary, from, druid) unless @context.execute?

      download(source_env, druid, cocina, items, source:)
      clone = @context.registration.register(**registration)
      stage(clone, items)
      write_structural(clone, cocina, items, from:, source_druid: druid)
      @context.versions.close(clone) unless keep_open
      @context.report(druid: clone, action: 'clone', result: 'ok', args: { from:, source: druid },
                      details: summary.except(:files))
      clone
    end

    private

    # A dry run validates the registration request and shows the plan, without downloading or creating anything.
    def plan(registration, summary, from, druid)
      @context.registration.register(**registration)
      @context.report(druid: nil, action: 'clone.plan', result: 'planned', args: { from:, source: druid }, details: summary)
      nil
    end

    def source_environment!(from)
      target = @context.environment.name
      raise UsageError, 'clone creates objects for testing: use --env stage or --env qa, not prod' if target == 'prod'
      raise UsageError, "--from must differ from --env (both are #{target})" if from.to_s == target

      SdrOps.environment(from)
    end

    def public_cocina(environment, druid)
      Downloads.json("#{environment.purl_url}/#{Druid.bare(druid)}.json") ||
        raise(Skip, "#{druid} isn't published in #{environment.name} (dark, or never accessioned): use --source dsa")
    end

    def dsa_cocina(environment, druid)
      token = @context.credentials_for(environment).token!
      Downloads.json("#{environment.dsa_url}/v1/objects/#{druid}", headers: { 'Authorization' => "Bearer #{token}" }) ||
        raise(Skip, "#{druid} not found in #{environment.name}")
    end

    # Each file comes from stacks if it's world-downloadable, otherwise from preservation.
    def plan_files(druid, cocina)
      unavailable = []
      items = cocina['structural']['contains'].flat_map { it['structural']['contains'] }.filter_map do |file|
        via = if file.dig('administrative', 'shelve') && file.dig('access', 'download') == 'world' then 'stacks'
              elsif file.dig('administrative', 'sdrPreserve') then 'preservation'
              end
        unless via
          unavailable << file['filename']
          next
        end

        { filename: file['filename'], size: file['size'], md5: digest(file, 'md5'), sha1: digest(file, 'sha1'), via:,
          local_path: File.join(@context.run_dir, 'downloads', Druid.bare(druid), file['filename']) }
      end
      [items, unavailable]
    end

    def summary(from, source, druid, cocina, items, unavailable) # rubocop:disable Metrics/ParameterLists
      { from:, source_druid: druid, cocina_source: source, source_version: cocina['version'],
        layout: cocina['structural']['contains'].map do |fs|
          { label: fs['label'], type: fs['type'].split('/').last, files: fs['structural']['contains'].map { it['filename'] } }
        end,
        files: items.map { it.slice(:filename, :size, :via) }, skipped_files: unavailable,
        total_bytes: items.sum { it[:size].to_i } }
    end

    def registration_args(cocina, from, druid, apo:, collection:, tags:)
      { apo:, type: cocina['type'], description: cocina['description'].except('purl'), geographic: cocina['geographic'],
        access: cocina['access'], collection:,
        source_id: "sdr-ops:clone-#{Druid.bare(druid)}-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}",
        tags: ["sdr-ops : clone of #{from} #{druid}", *tags] }
    end

    def download(source_env, druid, cocina, items, source:)
      pending = items.reject { Downloads.present?(it) }
      stacks, preserved = pending.partition { it[:via] == 'stacks' }
      Downloads.from_stacks(source_env, druid, stacks) if stacks.any?
      return if preserved.empty?

      # The published (public) version is preserved; for a DSA head version, take the latest preserved copy.
      Downloads.from_preservation(@context.transport_for(source_env), profile: @context.host,
                                                                      scratch_dir: @context.scratch_dir, druid:,
                                                                      items: preserved,
                                                                      version: source == 'public' ? cocina['version'] : nil)
    end

    def stage(clone, items)
      items.each do |item|
        remote = File.join(Druid.workspace_content_dir(clone), item[:filename])
        next if @context.transport.remote_md5(@context.host, remote) == item[:md5]

        @context.transport.put_file(@context.host, local_path: item[:local_path], remote_path: remote, md5: item[:md5])
      end
    end

    # One cocina update with the source's file sets and file attributes (new identifiers, this version).
    def write_structural(clone, cocina, items, from:, source_druid:)
      state = @context.fresh_state(clone)
      @context.versions.require_own_version!(state)
      kept = items.to_set { it[:filename] }
      file_sets = cocina['structural']['contains'].filter_map { copy_file_set(clone, it, kept, state.version) }
      structural = cocina['structural'].slice('hasMemberOrders')
                                       .merge('contains' => file_sets, 'isMemberOf' => state.cocina.structural.isMemberOf)
      new_cocina = SdrOps.valid_cocina!('cloned structural metadata') do
        state.cocina.new(structural: Cocina::Models::DROStructural.new(JSON.parse(JSON.generate(structural),
                                                                                  symbolize_names: true)))
      end
      description = @context.description(@context.reason || "Clone of #{from} #{source_druid}")
      state.cocina = @context.client.object(clone).update(params: new_cocina, user_name: @context.as, description:)
      @context.report(druid: clone, action: 'clone.structural', result: 'ok', args: { from:, source: source_druid },
                      details: { description:, file_sets: file_sets.map { [it['label'], it['structural']['contains'].size] } })
    end

    def copy_file_set(clone, file_set, kept, version)
      id = Files.file_set_id(clone)
      files = file_set['structural']['contains'].select { kept.include?(it['filename']) }.map do |file|
        file.merge('externalIdentifier' => Files.file_id(clone, id), 'version' => version)
      end
      return if files.empty?

      file_set.merge('externalIdentifier' => id, 'version' => version, 'structural' => { 'contains' => files })
    end

    def digest(file, type)
      file['hasMessageDigests']&.find { it['type'] == type }&.fetch('digest', nil)
    end
  end
end
