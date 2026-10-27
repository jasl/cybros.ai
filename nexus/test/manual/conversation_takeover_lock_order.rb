# Opt-in physical-plan characterization; never run in the parallel default suite.
# Run with bin/rails test test/manual/conversation_takeover_lock_order.rb in an isolated DB.
abort "explicit test database required" unless ENV["RAILS_TEST_APP_DB_NAME"].present?

require_relative "../services/conversations/takeover_test"

class ConversationTakeoverTest
  test "an unordered batch Stop can deadlock with ascending takeover owner locks" do
    newer = second_root_run
    reverse_run_heap
    acquired = Queue.new
    proceed = Queue.new
    candidate = start_database_call do
      @child.with_lock do
        Run.lock.find(@parent.id)
        acquired << true
        proceed.pop
        Run.lock.find(newer.id)
      end
      :accepted
    rescue ActiveRecord::Deadlocked
      :deadlocked
    end
    Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { acquired.pop }
    stopper = start_database_call do
      ApplicationRecord.transaction do
        heap_scan_only
        Conversations::Turns::Cancel.stop_now(@root)
      end
      :accepted
    rescue ActiveRecord::Deadlocked
      :deadlocked
    end
    wait_until_transitively_blocked_by(candidate.pid, stopper.pid)
    # Prove Stop already owns the higher row before it waits for the lower.
    assert_raises(ActiveRecord::LockWaitTimeout) do
      Run.transaction { Run.where(id: newer.id).lock("FOR UPDATE NOWAIT").load }
    end
    proceed << true
    outcomes = [finish_database_call(candidate), finish_database_call(stopper)]
    candidate = stopper = nil
    assert_equal [:accepted, :deadlocked], outcomes.sort
    # A deadlock loser rolls back the entire command, never half the batch.
    assert_equal @parent.reload.stopped?, newer.reload.stopped?
  ensure
    proceed << true if proceed
    stop_database_call(candidate) if candidate
    stop_database_call(stopper) if stopper
  end

  test "takeover NOWAIT rolls back its lower lock so reversed batch Stop can finish" do
    newer = second_root_run
    reverse_run_heap
    acquired = Queue.new
    proceed = Queue.new
    candidate = start_database_call do
      @child.with_lock do
        Run.lock.find(@parent.id)
        acquired << true
        proceed.pop
        Run.where(id: [@parent.id, newer.id]).order(:id).lock("FOR UPDATE NOWAIT").load
      end
      :accepted
    rescue ActiveRecord::LockWaitTimeout
      :busy
    end
    Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { acquired.pop }
    stopper = start_database_call do
      ApplicationRecord.transaction do
        heap_scan_only
        Conversations::Turns::Cancel.stop_now(@root)
      end
    end
    wait_until_transitively_blocked_by(candidate.pid, stopper.pid)
    proceed << true
    assert_equal :busy, finish_database_call(candidate)
    candidate = nil
    assert finish_database_call(stopper).accepted?
    stopper = nil
    assert @parent.reload.stopped?
    assert newer.reload.stopped?
  ensure
    proceed << true if proceed
    stop_database_call(candidate) if candidate
    stop_database_call(stopper) if stopper
  end

  private

    # Heap order is not a lock contract. A descending heap and ordinary hash
    # joins are a valid plan for the production unordered UPDATE. Keep this
    # physical-layout experiment confined to the isolated, serial test database.
    def reverse_run_heap
      connection = ApplicationRecord.lease_connection
      %w[runs variants turns].each do |table|
        begin
          connection.execute("CREATE INDEX takeover_reverse_#{table} ON #{table} (id DESC)")
          connection.execute("CLUSTER #{table} USING takeover_reverse_#{table}")
        ensure
          connection.execute("DROP INDEX IF EXISTS takeover_reverse_#{table}")
        end
      end
    end

    def heap_scan_only
      connection = ApplicationRecord.lease_connection
      connection.execute("SET LOCAL enable_indexscan = off")
      connection.execute("SET LOCAL enable_bitmapscan = off")
      connection.execute("SET LOCAL enable_nestloop = off")
    end
end
