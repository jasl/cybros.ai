# Child hints reduce latency; recurring passes recover lost hints. Ordinary
# replies and turn-owned completions have independent bounded cursors, so
# retained children cannot starve new completion or cancellation work. Relay
# owns its cross-conversation lock order and runs outside the turn converger's
# transaction. A source hint uses the same continuation shell for only that
# execution's inputs and turns, including completed owners of further work.
class AgentLoops::Spawn::RelayJob < ApplicationJob
  def perform(conversation_id = nil, cursor = {})
    options = cursor.symbolize_keys
    result = if options.key?(:source_loop_public_id)
      AgentLoops::SourceWork::Recovery.call(**options)
    else
      AgentLoops::Spawn::Relay.call(conversation_id: conversation_id, **options)
    end
    self.class.perform_later(conversation_id, result.cursor) if result.more?
  end
end
