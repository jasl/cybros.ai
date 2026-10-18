module ModelUsageRollups
  # Unlike bucketed reports, this total preserves the exact requested window.
  class ConversationSummary
    def self.call(account:, conversations:, from:, to:)
      values = UsageRecord.for_conversations(account: account, conversations: conversations)
        .where(recorded_at: from...to)
        .pick(*Counters.selections)
      Counters.render(Counters::COLUMNS.zip(values).to_h)
    end
  end
end
