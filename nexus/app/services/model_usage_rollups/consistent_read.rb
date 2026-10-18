module ModelUsageRollups
  module ConsistentRead
    # A composed report must not mix rows from before and after settlement or
    # rollup. Existing transactions bring their own repeatable-read snapshot.
    def self.call(&block)
      if UsageRecord.connection_pool.with_connection(&:transaction_open?)
        yield
      else
        UsageRecord.transaction(isolation: :repeatable_read, &block)
      end
    end
  end
end
