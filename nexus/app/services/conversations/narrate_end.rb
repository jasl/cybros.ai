module Conversations
  # THE END IS A PERSISTED EVENT (a fact that must be re-readable is a
  # row + a persisted event; the process lifecycle follows the
  # conversation). Archive and Tombstone call this inside their lock, for
  # every member they stamped, so the column write and the narration
  # commit together — and a follower on the cable hears the end even when
  # the next poll is already the family 404 (a tombstone's item is the
  # last item its feed ever carries; the reap destroys later). The
  # payload names the member itself: a socket that multiplexes many
  # streams reads whose end it is without a lookup.
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
