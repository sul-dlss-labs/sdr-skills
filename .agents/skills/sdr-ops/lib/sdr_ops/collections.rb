# frozen_string_literal: true

module SdrOps
  # Add an object to, or remove it from, a collection (structural.isMemberOf).
  class Collections
    def initialize(context)
      @context = context
    end

    def add(druid, collection)
      update(druid, collection, :add)
    end

    def remove(druid, collection)
      update(druid, collection, :remove)
    end

    private

    def update(druid, collection, operation)
      collection = Druid.normalize(collection)
      state = @context.fresh_state(druid)
      @context.versions.require_own_version!(state)
      raise Skip, "#{state.druid} isn't an item (only items belong to collections)" unless state.cocina.respond_to?(:structural)

      current = state.cocina.structural.isMemberOf
      updated = operation == :add ? (current | [collection]) : (current - [collection])
      raise Skip, "#{state.druid} is #{operation == :add ? 'already' : 'not'} in #{collection}" if updated == current

      @context.ensure_mutations_allowed!
      new_cocina = state.cocina.new(structural: state.cocina.structural.new(isMemberOf: updated))
      description = @context.description(@context.reason || state.description)
      if @context.execute?
        state.cocina = @context.client.object(state.druid).update(params: new_cocina, user_name: @context.as,
                                                                  description:)
      else
        state.cocina = new_cocina
        @context.mark_planned(state.druid)
      end
      @context.report(druid: state.druid, action: "collection.#{operation}", result: @context.execute? ? 'ok' : 'planned',
                      args: { collection: }, before: { isMemberOf: current }, after: { isMemberOf: updated },
                      details: { description: })
    end
  end
end
