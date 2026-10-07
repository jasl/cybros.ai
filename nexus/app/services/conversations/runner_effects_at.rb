module Conversations
  # Effects after a fork point include every variant in the source reach,
  # including hidden turns and inactive variants. The earliest claimed write
  # on each Runner describes that environment before successor work began.
  class RunnerEffectsAt
    def self.call(conversation:, position:)
      reach = Conversation::Timeline.new(conversation).reach
      expired = AgentRun.joins(conversation_turn_variant: :conversation_turn)
        .where(reach).where("conversation_turns.position > ?", position).where.not(details_pruned_at: nil)
      return AgentRuns::RunnerEffects.unavailable if expired.exists?

      scope = AgentRunTask.joins(agent_run: { conversation_turn_variant: :conversation_turn })
        .where(reach).where("conversation_turns.position > ?", position)
      AgentRuns::RunnerEffects.fact(AgentRuns::RunnerEffects.first_rows(scope))
    end
  end
end
