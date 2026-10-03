module Conversations
  # THE WORLD AT A FORK POINT, the PHYSICAL rule in ONE statement: the tree
  # before the successors' work is the FIRST runner-addressed write-kind
  # call a runner claimed strictly above the position, over EVERY loop of
  # EVERY variant of EVERY turn in the SOURCE's reach — candidates,
  # activation and concealment ignored, because a concealed turn's loop
  # still wrote and an old candidate's loop may have written first (the
  # overlay is a VIEW rule; the world is not). Background work can outlive
  # its turn, so claim time, not node creation order, determines the first
  # write. The SOURCE's reach, never the child's: the child's own reach ends
  # at the position.
  class WorldAt
    def self.call(conversation:, position:)
      expired = AgentLoop.joins(conversation_turn_variant: :conversation_turn)
        .where(Conversation::Timeline.new(conversation).reach)
        .where("conversation_turns.position > ?", position).where.not(details_pruned_at: nil)
      return AgentLoops::World.unavailable if expired.exists?

      row = AgentLoops::World.rows(
        AgentLoopNode.joins(agent_loop: { conversation_turn_variant: :conversation_turn })
      )
        .where(Conversation::Timeline.new(conversation).reach)
        .where("conversation_turns.position > ?", position)
        .order("agent_loop_nodes.claimed_at", "agent_loop_nodes.id")
        .first
      AgentLoops::World.fact(row)
    end
  end
end
