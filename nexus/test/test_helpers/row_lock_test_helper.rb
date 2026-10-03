require "timeout"

module RowLockTestHelper
  AsyncDatabaseCall = Data.define(:thread, :pid, :result)
  HeldRowLock = Data.define(:thread, :pid, :release, :errors)
  ROW_LOCK_WAIT_TIMEOUT = 5

  private

    def hold_row_lock(model, id, before_commit: nil)
      ready = Queue.new
      release = Queue.new
      errors = Queue.new
      thread = Thread.new do
        Thread.current.report_on_exception = false
        signaled = false
        ApplicationRecord.connection_pool.with_connection do |connection|
          ApplicationRecord.transaction do
            locked = model.lock.find(id)
            ready << connection.select_value("SELECT pg_backend_pid()").to_i
            signaled = true
            release.pop
            before_commit&.call(locked)
          end
        end
      rescue StandardError => error
        ready << error unless signaled
        errors << error
      end

      pid = Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { ready.pop }
      raise pid if pid.is_a?(Exception)

      HeldRowLock.new(thread: thread, pid: pid, release: release, errors: errors)
    end

    def release_row_lock(held_lock)
      held_lock.release << true if held_lock.thread.alive?
      assert held_lock.thread.join(ROW_LOCK_WAIT_TIMEOUT), "row-lock holder did not finish"
      raise held_lock.errors.pop unless held_lock.errors.empty?
    end

    def start_database_call(&)
      ready = Queue.new
      result = Queue.new
      thread = Thread.new do
        Thread.current.report_on_exception = false
        signaled = false
        ApplicationRecord.connection_pool.with_connection do |connection|
          ready << connection.select_value("SELECT pg_backend_pid()").to_i
          signaled = true
          result << yield
        end
      rescue StandardError => error
        ready << error unless signaled
        result << error
      end

      pid = Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { ready.pop }
      raise pid if pid.is_a?(Exception)

      AsyncDatabaseCall.new(thread: thread, pid: pid, result: result)
    end

    def wait_until_waiting_on_lock(*pids)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + ROW_LOCK_WAIT_TIMEOUT
      loop do
        waiting = ApplicationRecord.uncached do
          ApplicationRecord.connection_pool.with_connection do |connection|
            connection.select_values(<<~SQL).map!(&:to_i)
              SELECT pid
              FROM pg_stat_activity
              WHERE pid IN (#{pids.map { Integer(_1) }.join(", ")})
                AND wait_event_type = 'Lock'
            SQL
          end
        end
        return if (pids - waiting).empty?

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          states = ApplicationRecord.connection_pool.with_connection do |connection|
            connection.select_rows(<<~SQL)
              SELECT pid, state, wait_event_type, wait_event
              FROM pg_stat_activity
              WHERE pid IN (#{pids.map { Integer(_1) }.join(", ")})
              ORDER BY pid
            SQL
          end
          flunk(
            "database calls did not reach the row-lock barrier: " \
              "expected=#{pids.inspect} waiting=#{waiting.inspect} states=#{states.inspect}"
          )
        end

        sleep 0.01
      end
    end

    def wait_until_transitively_blocked_by(blocker_pid, *waiter_pids)
      blocker_pid = Integer(blocker_pid)
      waiter_pids = waiter_pids.map { Integer(_1) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + ROW_LOCK_WAIT_TIMEOUT

      loop do
        blocked_waiters = ApplicationRecord.uncached do
          ApplicationRecord.connection_pool.with_connection do |connection|
            connection.select_values(<<~SQL).map!(&:to_i)
              WITH RECURSIVE wait_graph(waiter_pid, blocker_pid) AS (
                SELECT activity.pid, blocker.pid
                FROM pg_stat_activity AS activity
                CROSS JOIN LATERAL unnest(pg_blocking_pids(activity.pid)) AS blocker(pid)
                WHERE activity.pid IN (#{waiter_pids.join(", ")})

                UNION

                SELECT wait_graph.waiter_pid, blocker.pid
                FROM wait_graph
                CROSS JOIN LATERAL unnest(pg_blocking_pids(wait_graph.blocker_pid)) AS blocker(pid)
              )
              SELECT DISTINCT waiter_pid
              FROM wait_graph
              WHERE blocker_pid = #{blocker_pid}
            SQL
          end
        end
        return if (waiter_pids - blocked_waiters).empty?

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          states = ApplicationRecord.connection_pool.with_connection do |connection|
            connection.select_rows(<<~SQL)
              SELECT pid, state, wait_event_type, wait_event, pg_blocking_pids(pid)
              FROM pg_stat_activity
              WHERE pid IN (#{waiter_pids.join(", ")})
              ORDER BY pid
            SQL
          end
          flunk(
            "database calls did not reach the expected lock blocker: " \
              "blocker=#{blocker_pid} waiters=#{waiter_pids.inspect} " \
              "blocked=#{blocked_waiters.inspect} states=#{states.inspect}"
          )
        end

        sleep 0.01
      end
    end

    def finish_database_call(call)
      assert call.thread.join(ROW_LOCK_WAIT_TIMEOUT), "database call did not finish"
      result = Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { call.result.pop }
      raise result if result.is_a?(Exception)

      result
    end

    def stop_database_call(call)
      call.thread.kill if call.thread.alive?
      call.thread.join
    end
end
