# frozen_string_literal: true

module SdrOps
  # The working copy of one object during a run: its cocina (with lock) and version status.
  # In a dry run, planned changes are applied here so later calls on the same item see them.
  class ObjectState
    attr_reader :druid
    attr_accessor :cocina, :version, :open, :openable, :closeable, :discardable, :assembling, :accessioning,
                  :description, :opened_by_run

    def self.load(druid, client:, ledger:)
      new(druid:).tap { |state| state.reload!(client:, ledger:) }
    end

    def initialize(druid:, cocina: nil, status: nil, opened_by_run: nil)
      @druid = druid
      assign(cocina:, status:, opened_by_run:) if status
    end

    # Reload from DSA in place, so anyone holding this state sees current values.
    def reload!(client:, ledger:)
      object = client.object(druid)
      status = object.version.status
      version = status.version.to_i
      opened_by_run = status.open? && ledger.opened_versions(druid).include?(version) ? version : nil
      assign(cocina: object.find, status:, opened_by_run:)
      self
    end

    def assign(cocina:, status:, opened_by_run:)
      @cocina = cocina
      @version = status.version.to_i
      @open = status.open? || false
      @openable = status.openable? || false
      @closeable = status.closeable? || false
      @discardable = status.discardable? || false
      @assembling = status.assembling? || false
      @accessioning = status.accessioning? || false
      @description = status.version_description
      @opened_by_run = opened_by_run
    end

    def open? = open
    def own_version? = open && opened_by_run == version

    def summary
      { version:, open:, description: }
    end

    # Planned (dry-run) open.
    def plan_open(description)
      self.version += 1
      self.cocina = cocina.new(version:)
      mark_opened(description)
    end

    # Real open: DSA returns the cocina for the new version.
    def apply_open(new_cocina, description)
      self.cocina = new_cocina
      self.version = new_cocina.version
      mark_opened(description)
    end

    def mark_closed(description = nil)
      self.description = description if description
      self.open = false
      self.closeable = false
      self.discardable = false
      self.openable = false # accessioning starts; DSA reports openable again once it finishes
      self.accessioning = true
      self.opened_by_run = nil
    end

    private

    def mark_opened(description)
      self.open = true
      self.openable = false
      self.closeable = true
      self.discardable = true
      self.description = description
      self.opened_by_run = version
    end
  end
end
