module Conversations
  # The recycle-bin verb: stamps `archived_at` over the root and its whole
  # subagent tree. No active-turn gate, because archive is reversible and a
  # running generation completes into the archived row harmlessly.
  class Archive
    def self.call(...) = new(...).call

    def initialize(conversation:)
      @conversation = conversation
    end

    def call
      @conversation.with_lock do
        next Outcome.refused(:not_found) if @conversation.tombstoned?
        # A follower never takes the verb directly; the parent's archive
        # reaches it through the tree stamp below.
        next Outcome.refused(:subagent_follows_parent) if @conversation.subagent?
        # A side is never binned: it dies with DELETE or with its parent.
        next Outcome.refused(:side_conversation) if @conversation.side?

        member_ids = SubagentTree.member_ids(@conversation)
        # The parent's sides go first — reference to a binned conversation
        # is nothing to keep, and a side's pin must never defer the reap.
        Conversation.sides_of(member_ids).find_each { |side| Sides::Discard.call(side) }
        stamped = Conversation.where(id: member_ids, archived_at: nil, tombstoned_at: nil).to_a
        Conversation.where(id: stamped.map(&:id)).touch_all(:archived_at)
        # The end, narrated on each stamped member's own feed, in this
        # transaction: a follower forgets the host and releases what its
        # loops started (NarrateEnd).
        NarrateEnd.call(stamped, reason: "archived")
        Outcome.accepted(@conversation)
      end
    end
  end
end
