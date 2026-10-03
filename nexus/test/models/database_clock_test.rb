require "test_helper"

# C2-4 A12: the one instant every windowed decision reads.
#
# Both claims here are load-bearing for admission, and both are things the
# obvious one-liner gets wrong.
class DatabaseClockTest < ActiveSupport::TestCase
  # A String would compare against window bounds by lexical accident and would
  # be cast on write without complaint — the half-open boundary rule would
  # break silently, which is the same class of defect as C2-3's phantom replay
  # conflict.
  test "the clock answers with a Time, not the text of one" do
    now = DatabaseClock.now

    assert_kind_of Time, now
    assert_in_delta Time.current, now, 5.seconds
  end

  # The trap this helper exists for. The query cache is on by default and keys
  # on SQL text, so a hand-rolled `select_value` returns a time from before
  # the caller's locks were taken.
  test "it advances inside a cached scope, where the plain read does not" do
    ActiveRecord::Base.cache do
      plain_first = ApplicationRecord.lease_connection.select_value(DatabaseClock::SQL)
      helper_first = DatabaseClock.now
      sleep 0.01
      plain_second = ApplicationRecord.lease_connection.select_value(DatabaseClock::SQL)
      helper_second = DatabaseClock.now

      assert_equal plain_first, plain_second,
        "if the plain read advances, the query cache stopped being the hazard this guards"
      assert_operator helper_second, :>, helper_first
    end
  end

  # `clock_timestamp()` and not `now()`: a transaction-frozen instant cannot
  # answer "is this window still applicable now that I hold its lock".
  test "it advances inside a transaction, where the transaction clock does not" do
    ApplicationRecord.transaction do
      frozen_first = ApplicationRecord.uncached do
        ApplicationRecord.lease_connection.select_value("SELECT now()")
      end
      first = DatabaseClock.now
      sleep 0.01
      frozen_second = ApplicationRecord.uncached do
        ApplicationRecord.lease_connection.select_value("SELECT now()")
      end
      second = DatabaseClock.now

      assert_equal frozen_first, frozen_second
      assert_operator second, :>, first
    end
  end
end
