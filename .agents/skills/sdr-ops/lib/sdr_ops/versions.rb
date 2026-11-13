# frozen_string_literal: true

module SdrOps
  # Open, close, and discard versions. See references/versions.md for DSA's rules.
  class Versions
    # Workflows whose steps DSA's discard cleanup removes; any others are left behind.
    CLEANED_ON_DISCARD = %w[accessionWF assemblyWF versioningWF].freeze
    USER_VERSION_MODES = %w[none new update update_if_existing].freeze

    def initialize(context)
      @context = context
    end

    # Open a new version. With a block, the version is closed when the block finishes (unless keep_open);
    # if the block raises, the version is left open so the user can decide what to do with it.
    def open(druid, description:, keep_open: false)
      state = @context.fresh_state(druid)
      before = state.summary
      raise_if_open!(state)
      raise Skip, "#{state.druid} isn't openable (accessioning or not yet accessioned)" unless state.openable

      @context.ensure_mutations_allowed!
      if @context.execute?
        cocina = @context.client.object(state.druid).version.open(description:, opening_user_name: @context.as)
        state.apply_open(cocina, description)
      else
        state.plan_open(description)
        @context.mark_planned(state.druid)
      end
      report(state, 'version.open', before:, args: { description: })
      return unless block_given?

      yield state
      close(state.druid) unless keep_open
    end

    # Treat a version someone else opened as this run's own, so content changes are allowed in it. Only when the
    # version is open, was opened by `opened_by` (its version_open event), and its description is `description`
    # (a String, matched exactly, or a Regexp). The ledger records the adoption, so later passes recognise it.
    def adopt(druid, opened_by:, description:)
      raise UsageError, 'adopt needs opened_by: and description:' if opened_by.to_s.empty? || description.to_s.empty?

      state = @context.fresh_state(druid)
      return state if state.own_version?
      raise Skip, "#{state.druid} has no open version to adopt" unless state.open?

      opener = opener(state)
      matches = description.is_a?(Regexp) ? description.match?(state.description.to_s) : state.description == description
      unless opener == opened_by && matches
        raise Skip, "#{state.druid} version #{state.version} (#{state.description.inspect}, opened by " \
                    "#{opener.inspect}) isn't the version to adopt (#{description.inspect}, opened by #{opened_by})"
      end

      @context.ensure_mutations_allowed!
      state.opened_by_run = state.version
      @context.mark_planned(state.druid) unless @context.execute?
      report(state, 'version.adopt', before: { version: state.version, open: true, description: state.description },
                                     after: state.summary, args: { opened_by:, description: description.to_s },
                                     details: { assembling: state.assembling })
      state
    end

    def close(druid, description: nil, accession: true, user_versions: nil, lane: nil)
      state = @context.fresh_state(druid)
      before = state.summary
      raise Skip, "#{state.druid} has no open version" unless state.open?
      raise Skip, "#{state.druid} can't be closed now (assembling or accessioning)" unless state.closeable
      if user_versions && !USER_VERSION_MODES.include?(user_versions)
        raise UsageError, "--user-versions must be one of #{USER_VERSION_MODES.join(', ')}"
      end

      @context.ensure_mutations_allowed!
      opened_by = opener(state)
      if @context.execute?
        params = { description:, user_name: @context.as, start_accession: accession, user_versions:, lane_id: lane }
        @context.client.object(state.druid).version.close(**params.compact)
      end
      state.mark_closed(description)
      report(state, 'version.close', before:, args: { description:, accession:, user_versions:, lane: }.compact,
                                     details: { opened_by: })
    end

    def discard(druid)
      state = @context.state(druid, refresh: true)
      before = state.summary
      raise Skip, "#{state.druid} has no open version" unless state.open?
      raise Skip, "#{state.druid} can't be discarded (DSA reports it isn't discardable)" unless state.discardable

      @context.ensure_mutations_allowed!
      details = { opened_by: opener(state), would_lose: lost_changes(state), left_behind: workflows_left_behind(state) }
      @context.client.object(state.druid).version.discard if @context.execute?
      @context.forget(state.druid)
      report(state, 'version.discard', before:, after: { version: state.version - 1, open: false }, details:)
    end

    # Content changes are only allowed in a version this run opened.
    def require_own_version!(state)
      return if state.own_version?

      raise_if_open!(state)

      raise Skip, "#{state.druid} has no open version: pass --open DESCRIPTION (or use versions.open in a script)"
    end

    # @return [String, nil] who opened the object's current version: its version_open event, or for
    # version 1, the registration event
    def opener(state)
      events = @context.client.object(state.druid).events.list(event_types: %w[version_open registration]) || []
      event = events.reverse.find { |e| e.event_type == 'version_open' && e.data['version'].to_s == state.version.to_s }
      event ||= events.find { |e| e.event_type == 'registration' } if state.version == 1
      event && (event.data['who'] || event.data['invoked_by'])
    rescue Dor::Services::Client::Error
      nil
    end

    private

    def raise_if_open!(state)
      return unless state.open?

      raise OpenVersionExists.new(druid: state.druid, version: state.version, description: state.description,
                                  opened_by: opener(state))
    end

    def report(state, action, before:, args: {}, after: nil, details: nil)
      @context.report(druid: state.druid, action:, result: @context.execute? ? 'ok' : 'planned', args:, before:,
                      after: after || state.summary, details:)
    end

    # What discarding would throw away: the open version's cocina compared with the last closed version's.
    def lost_changes(state)
      previous = @context.client.object(state.druid).version.find(state.version - 1)
      Diff.summary(previous, state.cocina)
    rescue Dor::Services::Client::Error => e
      { error: "couldn't load version #{state.version - 1}: #{e.message}" }
    end

    def workflows_left_behind(state)
      workflows = @context.client.object(state.druid).workflows.workflows
      workflows.reject { |wf| CLEANED_ON_DISCARD.include?(wf.workflow_name) }.filter_map do |wf|
        steps = wf.incomplete_processes_for(version: state.version).map(&:name)
        { workflow: wf.workflow_name, incomplete_steps: steps } if steps.any?
      end
    end
  end

  # A short, readable summary of how two cocina objects differ.
  module Diff
    module_function

    def summary(from, to)
      from_files = files_by_name(from)
      to_files = files_by_name(to)
      changed_sections = %i[access administrative description identification geographic].select do |section|
        from.respond_to?(section) && from.public_send(section)&.to_h != to.public_send(section)&.to_h
      end
      changed_sections << :isMemberOf if member_of(from) != member_of(to)
      {
        files_added: (to_files.keys - from_files.keys).sort,
        files_removed: (from_files.keys - to_files.keys).sort,
        files_changed: (from_files.keys & to_files.keys).reject { |name| from_files[name] == to_files[name] }.sort,
        sections_changed: changed_sections
      }
    end

    def files_by_name(cocina)
      return {} unless cocina.respond_to?(:structural) && cocina.structural

      cocina.structural.contains.flat_map { |fs| fs.structural.contains }.to_h do |file|
        [file.filename, file.to_h.except(:externalIdentifier, :version)]
      end
    end

    def member_of(cocina)
      cocina.respond_to?(:structural) && cocina.structural ? cocina.structural.isMemberOf.sort : []
    end
  end
end
