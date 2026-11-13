# frozen_string_literal: true

module SdrOps
  # Change an object's descriptive metadata from a script. See references/descriptive.md.
  class Descriptive
    MAX_REPORTED_CHANGES = 20

    def initialize(context)
      @context = context
    end

    # Yields a deep copy of the description as a Hash (symbol keys); the block edits it in place or returns
    # the new Hash. The result is validated as cocina and saved in a version this run opened (or adopted).
    # @return [Hash] the changed leaf paths, each [before, after]
    def update(druid)
      state = @context.fresh_state(druid)
      @context.versions.require_own_version!(state)
      before = state.cocina.description.to_h
      copy = Marshal.load(Marshal.dump(before))
      edited = yield(copy)
      after = edited.is_a?(Hash) ? edited : copy
      changes = self.class.changes(before, after)
      raise Skip, "#{state.druid}: the description wouldn't change" if changes.empty?

      new_cocina = SdrOps.valid_cocina!('description') do
        state.cocina.new(description: Cocina::Models::Description.new(after))
      end
      description = save(state, new_cocina)
      @context.report(druid: state.druid, action: 'description.update', result: @context.execute? ? 'ok' : 'planned',
                      args: { changed_paths: changes.size }, before: state.summary, after: state.summary,
                      details: { description:, changes: changes.first(MAX_REPORTED_CHANGES).to_h })
      changes
    end

    # Leaf-by-leaf differences between two nested Hash/Array values.
    # @return [Hash{String => Array}] path => [before, after]
    def self.changes(before, after)
      old = leaves(before)
      new = leaves(after)
      (old.keys | new.keys).reject { old[it] == new[it] }.to_h { [it, [old[it], new[it]]] }
    end

    def self.leaves(value, prefix = '')
      case value
      when Hash then value.flat_map { |key, child| leaves(child, "#{prefix}.#{key}").to_a }.to_h
      when Array then value.each_with_index.flat_map { |child, index| leaves(child, "#{prefix}[#{index}]").to_a }.to_h
      else { prefix.delete_prefix('.') => value }
      end
    end

    private

    # @return [String] the event description recorded with the update
    def save(state, new_cocina)
      @context.ensure_mutations_allowed!
      description = @context.description(@context.reason || state.description)
      if @context.execute?
        state.cocina = @context.client.object(state.druid).update(params: new_cocina, user_name: @context.as,
                                                                  description:)
      else
        state.cocina = new_cocina
        @context.mark_planned(state.druid)
      end
      description
    end
  end
end
