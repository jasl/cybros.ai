module Conversations
  # Archive and Tombstone publish their visibility change in the mutation
  # transaction. Archive preserves accepted execution and its followers;
  # tombstone ends the feed before later reads conceal it. The payload names
  # each member so multiplexed consumers need no ownership lookup.
  module NarrateEnd
    REASONS = %w[archived tombstoned].freeze

    def self.call(conversations, reason:)
      raise ArgumentError, "unknown end reason #{reason.inspect}" unless REASONS.include?(reason)

      conversations.each do |conversation|
        ConversationEvent::Append.call(host: conversation, items: [{
          type: "conversation_ended",
          payload: { "reason" => reason, "conversation_public_id" => conversation.public_id },
        }])
      end
    end
  end
end
