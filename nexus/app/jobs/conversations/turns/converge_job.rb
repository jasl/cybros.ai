# Completion wakes name their invocation; a loop transition or successor
# names its loop. The recurring floor carries independent cursors over the
# four source windows, recovering work whose precise wake was lost.
class Conversations::Turns::ConvergeJob < ApplicationJob
  BATCH = 200

  def perform(conversation_id = nil, options = {})
    result = Conversations::Turns::Converge.call(
      conversation_id: conversation_id, agent_loop_id: options["agent_loop_id"],
      invocation_id: options["invocation_id"],
      cursors: options.fetch("cursors", {}), batch: BATCH
    )
    self.class.perform_later(nil, { "cursors" => result.value.cursor }) if result.value.more?
  end
end
