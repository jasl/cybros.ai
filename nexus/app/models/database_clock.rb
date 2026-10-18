# What time is it now that my locks are held: `clock_timestamp()`, not the
# transaction-frozen `now()`, read `uncached` because the query cache keys on
# SQL text and would answer the first read's instant.
module DatabaseClock
  SQL = "SELECT clock_timestamp()".freeze

  # A Time, never a String (database_clock_test.rb pins it).
  def self.now
    ApplicationRecord.uncached do
      ApplicationRecord.lease_connection.select_value(SQL)
    end
  end
end
