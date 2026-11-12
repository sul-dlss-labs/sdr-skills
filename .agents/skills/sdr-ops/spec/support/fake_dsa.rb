# frozen_string_literal: true

# An in-memory stand-in for the parts of Dor::Services::Client that sdr-ops uses, with just enough of DSA's
# rules (open version required for updates, lock checks, status flags) to exercise the library honestly.
class FakeDsa
  Record = Struct.new(:cocina, :version, :open, :openable, :closeable, :discardable, :assembling, :accessioning,
                      :description, :events, :workflows, :history, keyword_init: true)

  attr_reader :calls

  def initialize
    @records = {}
    @calls = []
    @locks = 1
  end

  def add(cocina, open: false, description: 'Initial version', openable: nil, closeable: nil, events: [], workflows: {})
    druid = cocina.externalIdentifier
    @records[druid] = Record.new(cocina:, version: cocina.version, open:, openable: openable.nil? ? !open : openable,
                                 closeable: closeable.nil? ? open : closeable, discardable: open, assembling: false,
                                 accessioning: false, description:, events:, workflows:,
                                 history: { cocina.version => cocina })
    self
  end

  def record(druid)
    @records.fetch(druid) { raise Dor::Services::Client::NotFoundResponse, "Couldn't find #{druid}" }
  end

  def log(druid, method, **args)
    @calls << [druid, method, args]
  end

  def calls_for(method)
    @calls.select { |call| call[1] == method }
  end

  def next_lock
    @locks += 1
    "lock-#{@locks}"
  end

  def object(druid) = FakeObject.new(self, druid)

  # Stands in for Dor::Services::Client.objects.register: mints a druid and stores an open version 1.
  def register(params:, user_name: nil, **)
    druid = "druid:#{%w[xx665rt9579 bb000bb0000 cc111cc1111][@records.size % 3]}"
    log(druid, :register, user_name:, request: params)
    attributes = params.to_h.merge(externalIdentifier: druid, access: params.access&.to_h || { view: 'world', download: 'world' })
    attributes[:description] = attributes[:description].merge(purl: "https://purl.stanford.edu/#{druid.delete_prefix('druid:')}")
    cocina = Cocina::Models.with_metadata(Cocina::Models.build(attributes), next_lock)
    add(cocina, open: true, description: 'Initial version', events: [event('registration', who: user_name)])
    cocina
  end

  # Stands in for Dor::Services::Client.objects
  def objects = self

  def event(type, data)
    Dor::Services::Client::Events::Event.new(event_type: type, data: data.transform_keys(&:to_s), timestamp: Time.now.iso8601)
  end

  # workflow XML in the shape DSA returns
  def self.workflow_xml(druid, name, steps)
    processes = steps.map do |step|
      attrs = { name: step[:name], status: step[:status], version: step[:version] || 1, laneId: 'default' }
      attrs[:errorMessage] = step[:error] if step[:error]
      "<process #{attrs.map { |k, v| "#{k}=\"#{v}\"" }.join(' ')}/>"
    end
    "<workflow repository=\"dor\" objectId=\"#{druid}\" id=\"#{name}\">#{processes.join}</workflow>"
  end

  class FakeObject
    def initialize(dsa, druid)
      @dsa = dsa
      @druid = druid
    end

    def find
      @dsa.log(@druid, :find)
      rec.cocina
    end

    def version = FakeVersion.new(@dsa, @druid)
    def events = FakeEvents.new(rec)
    def administrative_tags = FakeTags.new(@dsa, @druid)
    def workflow(name) = FakeWorkflow.new(@dsa, @druid, name)

    def workflows
      Dor::Services::Response::Workflows.new(
        xml: Nokogiri::XML("<workflows objectId=\"#{@druid}\">#{rec.workflows.values.join}</workflows>")
      )
    end

    def update(params:, user_name: nil, description: nil, skip_lock: false, **)
      @dsa.log(@druid, :update, user_name:, description:, cocina: params)
      raise 'DSA would 500: updates need an open version' unless rec.open
      unless skip_lock || params.lock == rec.cocina.lock
        raise Dor::Services::Client::PreconditionFailedResponse.new(response: nil,
                                                                    errors: [{ 'title' => 'Stale lock' }])
      end

      rec.cocina = Cocina::Models.with_metadata(Cocina::Models.without_metadata(params), @dsa.next_lock)
    end

    private

    def rec = @dsa.record(@druid)
  end

  class FakeVersion
    def initialize(dsa, druid)
      @dsa = dsa
      @druid = druid
    end

    def status
      Dor::Services::Client::ObjectVersion::VersionStatus.new(
        versionId: rec.version, open: rec.open, openable: rec.openable, assembling: rec.assembling,
        accessioning: rec.accessioning, closeable: rec.closeable, discardable: rec.discardable,
        versionDescription: rec.description
      )
    end

    def current = rec.version.to_s

    def open(description:, opening_user_name: nil, **)
      @dsa.log(@druid, :open, description:, opening_user_name:)
      raise Dor::Services::Client::UnexpectedResponse.new(response: nil, errors: [{ 'title' => 'already open' }]) if rec.open

      rec.version += 1
      rec.open = true
      rec.openable = false
      rec.closeable = true
      rec.discardable = true
      rec.description = description
      rec.cocina = Cocina::Models.with_metadata(Cocina::Models.without_metadata(rec.cocina).new(version: rec.version),
                                                @dsa.next_lock)
      rec.history[rec.version] = rec.cocina
      rec.events << @dsa.event('version_open', who: opening_user_name, version: rec.version.to_s, description:)
      rec.cocina
    end

    def close(**params)
      @dsa.log(@druid, :close, **params)
      raise 'not open' unless rec.open

      rec.open = false
      rec.closeable = false
      rec.discardable = false
      rec.accessioning = true
      rec.description = params[:description] if params[:description]
      'closed'
    end

    def discard
      @dsa.log(@druid, :discard)
      rec.history.delete(rec.version)
      rec.version -= 1
      rec.cocina = rec.history.fetch(rec.version)
      rec.open = false
    end

    def find(version)
      rec.history.fetch(version.to_i)
    end

    private

    def rec = @dsa.record(@druid)
  end

  class FakeTags
    def initialize(dsa, druid)
      @dsa = dsa
      @druid = druid
    end

    def create(tags:)
      @dsa.log(@druid, :tags_create, tags:)
    end
  end

  class FakeEvents
    def initialize(rec)
      @rec = rec
    end

    def list(event_types: nil, **)
      event_types ? @rec.events.select { |e| event_types.include?(e.event_type) } : @rec.events
    end
  end

  class FakeWorkflow
    def initialize(dsa, druid, name)
      @dsa = dsa
      @druid = druid
      @name = name
    end

    def create(version:, lane_id: 'default', **)
      @dsa.log(@druid, :workflow_create, workflow: @name, version:, lane_id:)
    end

    def find
      xml = @dsa.record(@druid).workflows.fetch(@name) { "<workflow objectId=\"#{@druid}\" id=\"#{@name}\"/>" }
      Dor::Services::Response::Workflow.new(xml:)
    end

    def skip_all(note:)
      @dsa.log(@druid, :skip_all, workflow: @name, note:)
    end

    def process(step) = FakeProcess.new(@dsa, @druid, @name, step, find)
  end

  class FakeProcess
    def initialize(dsa, druid, workflow, step, workflow_doc)
      @dsa = dsa
      @druid = druid
      @workflow = workflow
      @step = step
      @workflow_doc = workflow_doc
    end

    def update(status:, current_status: nil, note: nil, **)
      actual = @workflow_doc.process_for_recent_version(name: @step).status
      if current_status && actual != current_status
        raise Dor::Services::Client::ConflictResponse.new(response: nil, errors: [{ 'title' => 'Conflict' }])
      end

      @dsa.log(@druid, :process_update, workflow: @workflow, step: @step, status:, current_status:, note:)
    end
  end
end
