module Conversations
  # A client edit keeps the version it read across any work before this command.
  # Optimistic save also fences a writer that wins after the controller's read.
  class Update
    def self.call(conversation:, lock_version:, changes:)
      return Outcome.refused(:stale_object) if conversation.lock_version != lock_version

      conversation.assign_attributes(changes)
      if conversation.save
        Outcome.accepted(conversation)
      else
        Outcome.invalid(conversation)
      end
    rescue ActiveRecord::StaleObjectError
      Outcome.refused(:stale_object)
    end
  end
end
