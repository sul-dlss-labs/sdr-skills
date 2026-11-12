# frozen_string_literal: true

module SdrOps
  # Register new items, the way Argo does: register with DSA, tag "Registered By : <sunet>", create
  # registrationWF for version 1, and optionally close version 1 to start accessioning.
  # The run that registers an object owns its version 1, so files can be added before accessioning.
  class Registration
    ITEM_TYPES = %w[book document file geo image manuscript map media object page photograph three_dimensional
                    track webarchive_binary webarchive_seed].freeze
    REGISTERED_BY_PREFIX = 'Registered By : '
    VIEWS = %w[world stanford location-based citation-only dark].freeze
    DOWNLOADS = %w[world stanford location-based none].freeze

    def initialize(context)
      @context = context
    end

    # @return [String, nil] the new druid (nil in a dry run)
    def register(title:, apo:, source_id: nil, type: 'object', collection: nil, tags: [], view: nil, download: nil,
                 workflow: 'registrationWF', accession: false)
      request = build_request(title:, apo:, source_id: source_id || default_source_id, type:, collection:, view:,
                              download:)
      tags = ["#{REGISTERED_BY_PREFIX}#{@context.as}", *tags].uniq
      args = { source_id: request.identification.sourceId, apo: request.administrative.hasAdminPolicy, type:,
               collection: request.structural.isMemberOf.first, tags:, workflow:, accession: }.compact
      return plan(request, args) unless @context.execute?

      @context.ensure_mutations_allowed!
      druid = create(request, tags:, workflow:)
      @context.report(druid:, action: 'object.register', result: 'ok', args:, after: { version: 1, open: true },
                      details: { title: })
      @context.versions.close(druid) if accession
      druid
    end

    def build_request(title:, apo:, source_id:, type:, collection:, view:, download:)
      raise UsageError, 'A title is required' if title.to_s.strip.empty?
      raise UsageError, "--view must be one of #{VIEWS.join(', ')}" if view && !VIEWS.include?(view)
      raise UsageError, "--download must be one of #{DOWNLOADS.join(', ')}" if download && !DOWNLOADS.include?(download)

      access = { view:, download: }.compact
      Cocina::Models::RequestDRO.new({
        type: Cocina::Models::ObjectType.public_send(item_type!(type)),
        version: 1,
        administrative: { hasAdminPolicy: Druid.normalize(apo) },
        identification: { sourceId: source_id },
        description: { title: [{ value: title }] },
        access: access.empty? ? nil : access,
        structural: { contains: [], isMemberOf: collection ? [Druid.normalize(collection)] : [] }
      }.compact)
    # cocina-models 0.133.0's validator can raise TypeError while formatting some errors.
    rescue Cocina::Models::ValidationError, Dry::Struct::Error, TypeError => e
      raise UsageError, "Invalid registration: #{e.message}"
    end

    private

    def create(request, tags:, workflow:)
      cocina = @context.client.objects.register(params: request, user_name: @context.as)
      druid = cocina.externalIdentifier
      object = @context.client.object(druid)
      object.administrative_tags.create(tags:)
      object.workflow(workflow).create(version: 1)
      druid
    end

    def plan(request, args)
      followups = ["tag #{args[:tags].join(', ')}", "create #{args[:workflow]} for version 1"]
      followups << 'close version 1, which starts accessionWF' if args[:accession]
      @context.report(druid: nil, action: 'object.register', result: 'planned', args:,
                      details: { request: request.to_h, then: followups })
      nil
    end

    def item_type!(type)
      name = type.to_s.tr('-', '_')
      return name if ITEM_TYPES.include?(name)

      raise UsageError, "--type must be one of #{ITEM_TYPES.join(', ')} (got #{type.inspect})"
    end

    def default_source_id
      "sdr-ops:#{@context.as}-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}"
    end
  end
end
