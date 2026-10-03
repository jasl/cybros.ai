module Conversations
  # Marks the root and its whole subagent tree for reap (an unreachable
  # subagent must never stay live); live work anywhere in the tree refuses
  # rather than being canceled on the caller's behalf. Fork children are
  # independent — except a SIDE, which is reference-only: on a side the
  # verb reaps at once, and on a parent its sides are reaped first,
  # cancelled rather than refused.
  class Tombstone
    def self.call(...) = new(...).call

    def initialize(conversation:)
      @conversation = conversation
    end

    def call
      @conversation.with_lock do
        next Outcome.refused(:already_tombstoned) if @conversation.tombstoned?
        next Outcome.refused(:subagent_follows_parent) if @conversation.subagent?
        next discard_side if @conversation.side?

        member_ids = SubagentTree.member_ids(@conversation)
        # Bypass the query cache after taking the root lock, so an active
        # turn that terminalized on another connection is not conservatively
        # refused from a pre-lock cached read.
        busy = ApplicationRecord.uncached do
          ConversationTurn.active.where(conversation_id: member_ids).exists?
        end
        next Outcome.refused(:conversation_busy) if busy

        Conversation.sides_of(member_ids).find_each { |side| Sides::Discard.call(side) }
        stamped = Conversation.where(id: member_ids, tombstoned_at: nil).to_a
        Conversation.where(id: stamped.map(&:id)).touch_all(:tombstoned_at)
        # The feed's LAST item, in this transaction: the next poll is the
        # 404, the cable carries this one (NarrateEnd).
        NarrateEnd.call(stamped, reason: "tombstoned")
        Outcome.accepted(@conversation)
      end
    end

    private

      def discard_side
        Sides::Discard.call(@conversation)
        Outcome.accepted(@conversation)
      end
  end
end
