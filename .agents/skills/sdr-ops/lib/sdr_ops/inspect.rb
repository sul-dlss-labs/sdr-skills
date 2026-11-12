# frozen_string_literal: true

module SdrOps
  # Read-only lookups. Available as `sdr.read` in scripts.
  class Inspect
    def initialize(context)
      @context = context
    end

    # Version status, who opened an open version, errored workflow steps, and collections.
    def status(druid)
      state = @context.state(druid, refresh: true)
      object = @context.client.object(state.druid)
      cocina = state.cocina
      {
        druid: state.druid,
        version: state.version,
        open: state.open,
        openable: state.openable,
        closeable: state.closeable,
        discardable: state.discardable,
        assembling: state.assembling,
        accessioning: state.accessioning,
        version_description: state.description,
        opened_by: state.open? ? @context.versions.opener(state) : nil,
        opened_by_this_run: state.own_version?,
        workflow_errors: object.workflows.errors_for(version: state.version),
        collections: cocina.respond_to?(:structural) && cocina.structural ? cocina.structural.isMemberOf : [],
        content_type: cocina.type,
        title: cocina.description.title.first&.value
      }
    end

    # @return [Hash] cocina as a hash: the current version, a given version, or the public (purl) copy
    def cocina(druid, version: nil, public: false)
      druid = Druid.normalize(druid)
      return public_cocina(druid) if public
      return @context.client.object(druid).version.find(version.to_i).to_h if version

      @context.state(druid).cocina.to_h
    end

    # Public cocina from purl (what was last published), or nil if not published.
    def public_cocina(druid)
      uri = URI("#{@context.environment.purl_url}/#{Druid.bare(druid)}.json")
      response = Net::HTTP.get_response(uri)
      return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)
      return if response.is_a?(Net::HTTPNotFound)

      raise Error, "#{uri} returned HTTP #{response.code}"
    end

    def files(druid, workspace: false)
      @context.files.list(druid, workspace:)
    end

    def workflows(druid, workflow: nil, version: nil)
      druid = Druid.normalize(druid)
      object = @context.client.object(druid)
      workflows = workflow ? [object.workflow(workflow).find] : object.workflows.workflows
      workflows.flat_map do |wf|
        wf.processes.filter_map do |process|
          next if version && process.version != version.to_i

          { druid:, workflow: wf.workflow_name, step: process.name, version: process.version,
            status: process.status, datetime: process.datetime, attempts: process.attempts,
            lane: process.lane_id, note: process.note, error_message: process.error_message,
            active_version: process.active_version? }
        end
      end
    end

    def events(druid, types: nil)
      druid = Druid.normalize(druid)
      (@context.client.object(druid).events.list(event_types: types) || []).map do |event|
        { druid:, event_type: event.event_type, timestamp: event.timestamp, data: event.data }
      end
    end
  end
end
