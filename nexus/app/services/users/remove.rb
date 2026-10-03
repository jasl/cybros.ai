module Users
  class Remove
    def self.call(user:)
      outcome = user.remove
      if outcome == :removed && user.agent?
        # One wake covers the Profile and its removed instance definitions.
        ActiveRecord.after_all_transactions_commit { StopAgentWorkJob.perform_later(user.id) }
      end
      outcome
    end
  end
end
