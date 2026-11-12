# frozen_string_literal: true

module SdrOps
  # Run workflows, set step states, and check progress. See references/workflows.md.
  class Workflows
    STATUSES = %w[waiting started completed queued error skipped retrying].freeze
    NEEDS_OPEN_VERSION = %w[gisAssemblyWF gisDerivativeWF assemblyWF].freeze
    STARTED_BY_CLOSE = %w[accessionWF].freeze
    LANES = %w[low default high].freeze

    def initialize(context)
      @context = context
    end

    # Create (or replace) a workflow for a version: the current one unless given.
    def run(druid, workflow, version: nil, lane: 'default')
      if STARTED_BY_CLOSE.include?(workflow)
        raise UsageError, "#{workflow} is started by closing a version: use `version close` instead"
      end
      raise UsageError, "--lane must be one of #{LANES.join(', ')}" unless LANES.include?(lane)

      state = @context.fresh_state(druid)
      version = (version || state.version).to_i
      if NEEDS_OPEN_VERSION.include?(workflow) && !(state.open? && state.version == version)
        raise Skip, "#{workflow} needs version #{version} of #{state.druid} to be open"
      end

      @context.ensure_mutations_allowed!
      @context.client.object(state.druid).workflow(workflow).create(version:, lane_id: lane) if @context.execute?
      @context.mark_planned(state.druid)
      report(state, 'workflow.run', args: { workflow:, version:, lane: },
                                    details: version_context(state))
    end

    # Set one step's status. `expect` defaults to the status read just before, so a concurrent change
    # makes DSA return a conflict instead of being overwritten.
    def set(druid, workflow, step, status, expect: nil, note: nil)
      raise UsageError, "Status must be one of #{STATUSES.join(', ')}" unless STATUSES.include?(status)

      state = @context.fresh_state(druid)
      process = current_process(state, workflow, step)
      raise Skip, "#{state.druid} has no #{workflow}:#{step} step" unless process

      expect ||= process.status
      @context.ensure_mutations_allowed!
      note = attribution("set #{step} to #{status}", note)
      if @context.execute?
        begin
          @context.client.object(state.druid).workflow(workflow).process(step)
                  .update(status:, current_status: expect, note:)
        rescue Dor::Services::Client::ConflictResponse
          raise Skip, "#{state.druid} #{workflow}:#{step} is no longer #{expect.inspect}; not changed"
        end
      end
      report(state, 'workflow.set', args: { workflow:, step:, status:, expect:, note: },
                                    before: { step_status: process.status, version: process.version },
                                    details: version_context(state))
    end

    # error -> waiting, like Argo's workflow-grid reset button.
    def reset(druid, workflow, step, note: nil)
      set(druid, workflow, step, 'waiting', expect: 'error', note:)
    end

    def skip_all(druid, workflow, note:)
      raise UsageError, 'skip-all needs a --note' if note.nil? || note.strip.empty?

      state = @context.fresh_state(druid)
      @context.ensure_mutations_allowed!
      note = attribution('skipped all steps', note)
      @context.client.object(state.druid).workflow(workflow).skip_all(note:) if @context.execute?
      report(state, 'workflow.skip_all', args: { workflow:, note: }, details: version_context(state))
    end

    # Evaluate "WF:complete" or "WF:STEP:complete" for the object's current version, now.
    # @return [Hash] { druid:, check:, state: complete|pending|error, ... }
    def check(druid, until_spec)
      workflow, step = parse_until(until_spec)
      druid = Druid.normalize(druid)
      version = @context.client.object(druid).version.current.to_i
      wf = @context.client.object(druid).workflow(workflow).find
      result = step ? check_step(wf, step, version) : check_workflow(wf, version)
      { druid:, check: until_spec, version:, **result }
    end

    def parse_until(spec)
      parts = spec.to_s.split(':')
      unless parts.last == 'complete' && parts.length.between?(2, 3)
        raise UsageError, "--until must look like WF:complete or WF:STEP:complete (got #{spec.inspect})"
      end

      [parts[0], parts.length == 3 ? parts[1] : nil]
    end

    private

    # The client returns an empty Process (name nil) rather than nil when a step doesn't exist.
    def current_process(state, workflow, step)
      wf = @context.client.object(state.druid).workflow(workflow).find
      process = wf.process_for(name: step, version: state.version)
      process = wf.process_for_recent_version(name: step) if process.name.nil?
      process.name ? process : nil
    end

    def check_step(workflow_doc, step, version)
      process = workflow_doc.process_for(name: step, version:)
      return { state: 'pending', detail: 'step not started for this version' } if process.name.nil?

      case process.status
      when 'completed', 'skipped' then { state: 'complete', status: process.status }
      when 'error' then { state: 'error', status: 'error', error_message: process.error_message }
      else { state: 'pending', status: process.status }
      end
    end

    def check_workflow(workflow_doc, version)
      return { state: 'pending', detail: 'workflow not started for this version' } unless workflow_doc.active_for?(version:)

      incomplete = workflow_doc.incomplete_processes_for(version:)
      errored = incomplete.find { |p| p.status == 'error' }
      return { state: 'error', step: errored.name, error_message: errored.error_message } if errored
      return { state: 'complete' } if incomplete.empty?

      { state: 'pending', step: incomplete.first.name, status: incomplete.first.status }
    end

    def attribution(action, note)
      [[action, "by #{@context.as} via sdr-ops"].join(' '), note, @context.reason, @context.ticket]
        .compact.reject(&:empty?).uniq.join('; ')
    end

    # What the dry run shows about the version a workflow action touches, whoever opened it.
    def version_context(state)
      { version: state.version, version_open: state.open?, version_description: state.description,
        opened_by: state.open? ? @context.versions.opener(state) : nil }.compact
    end

    def report(state, action, args:, before: nil, details: nil)
      @context.report(druid: state.druid, action:, result: @context.execute? ? 'ok' : 'planned', args:, before:,
                      details:)
    end
  end
end
