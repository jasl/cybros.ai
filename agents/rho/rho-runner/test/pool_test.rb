require "test_helper"
require "async"

class RunnerPoolTest < Minitest::Test
  Child = Data.define(:level, :path, :answer)

  def test_a_waiting_handler_returns_its_startup_ticket_before_it_finishes
    pool = Rho::Runner::Pool.new(worker_threads: 1)
    entered = Thread::Queue.new
    release = Thread::Queue.new
    context = Rho::Runner::ExecutionContext.new
    caller = Thread.new do
      pool.run(pool.reserve, context) do
        entered << true
        release.pop
        42
      end
    end
    assert entered.pop(timeout: 2)
    ticket = reserve_within(pool)
    refute_nil ticket, "a waiting handler must allow its child to start"
    assert_nil pool.reserve, "only one additional job may wait to start"
    assert_equal 1, pool.in_flight
    release << true
    assert_equal 42, caller.value
    assert_nil pool.reserve, "handler exit must not return the startup ticket twice"
  ensure
    release << true if release
    caller&.join(2)
    pool&.release(ticket)
    pool&.stop
  end

  def test_a_native_startup_holds_its_ticket_until_it_can_yield
    pool = Rho::Runner::Pool.new(worker_threads: 1)
    entered = Thread::Queue.new
    native_release = Thread::Queue.new
    handler_release = Thread::Queue.new
    caller = Thread.new do
      pool.run(pool.reserve, Rho::Runner::ExecutionContext.new) do
        entered << true
        Fiber.blocking { native_release.pop }
        handler_release.pop
        42
      end
    end
    assert entered.pop(timeout: 2)
    assert_nil pool.reserve, "native computation has not yielded its startup capacity"
    native_release << true
    ticket = reserve_within(pool)
    refute_nil ticket
    assert_nil pool.reserve
    handler_release << true
    assert_equal 42, caller.value
    assert_nil pool.reserve, "completion cannot duplicate the returned ticket"
  ensure
    native_release << true if native_release
    handler_release << true if handler_release
    caller&.join(2)
    pool&.release(ticket)
    pool&.stop
  end

  def test_a_started_handler_renews_without_another_control_mailbox_to_wake_the_wait
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.02)
    extended = Thread::Queue.new
    release = Thread::Queue.new
    extension = Rho::Runner::DeadlineExtension.new(park_seconds: 0.06,
      deadline_at: (Time.now + 0.06).iso8601, clock: -> { now }) do
      extended << true
      [now + 1, (Time.now + 1).iso8601, 1]
    end
    context = Rho::Runner::ExecutionContext.new(deadline: now + 0.06, extension: extension)
    caller = Thread.new { pool.run(pool.reserve, context) { release.pop; 42 } }
    assert extended.pop(timeout: 1), "starting the handler must wake the control wait to arm renewal"
    refute context.cancelled?
    release << true
    assert_equal 42, caller.value
  ensure
    release << true if release
    caller&.join(2)
    pool&.stop
  end

  def test_a_renewable_unstarted_claim_expires_and_replaces_a_host_that_blocked_after_its_prior_ack
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.1)
    entered = Thread::Queue.new
    native_release = Thread::Queue.new
    first_context = Rho::Runner::ExecutionContext.new(deadline: now + 0.05)
    first = Thread.new do
      capture_cancelled do
        pool.run(pool.reserve, first_context) do
          sleep 0.08
          entered << Thread.current
          Fiber.blocking { native_release.pop }
        end
      end
    end
    original = entered.pop(timeout: 2)
    refute_nil original
    assert first.join(2)
    assert_equal :deadline, first.value.reason

    extensions = Thread::Queue.new
    extension = Rho::Runner::DeadlineExtension.new(park_seconds: 0.06,
      deadline_at: (Time.now + 0.06).iso8601, clock: -> { now }) do
      extensions << true
      [now + 1, (Time.now + 1).iso8601, 1]
    end
    waiting_context = Rho::Runner::ExecutionContext.new(deadline: now + 0.06, extension: extension)
    ticket = reserve_within(pool)
    refute_nil ticket
    waiting = Thread.new do
      capture_cancelled do
        pool.run(ticket, waiting_context) { flunk "an expired startup must not run" }
      end
    end
    assert waiting.join(0.5), "unstarted work must keep its initial deadline instead of renewing forever"
    assert_equal :deadline, waiting.value.reason
    assert extensions.empty?, "only a handler that actually started may renew its claim"
    replacement_ticket = reserve_within(pool)
    refute_nil replacement_ticket
    replacement = pool.run(replacement_ticket, Rho::Runner::ExecutionContext.new) { Thread.current }
    refute_same original, replacement
    native_release << true
    assert original.join(2)
    final_ticket = reserve_within(pool)
    refute_nil final_ticket
    assert_nil pool.reserve, "a late native return must not duplicate the startup permit"
  ensure
    waiting_context&.cancel(:shutdown)
    native_release << true if native_release
    first&.join(2)
    waiting&.join(2)
    pool&.release(final_ticket)
    pool&.stop
  end

  def test_three_levels_share_one_worker_without_losing_live_handlers_or_extension_leases
    assert_nested_work(workers: 1, parents: 1)
  end

  def test_waiting_parents_at_and_above_the_worker_count_keep_fixed_execution_capacity
    assert_nested_work(workers: 4, parents: 4)
    assert_nested_work(workers: 4, parents: 20)
  end

  def test_a_fiber_ignoring_cancellation_finishes_on_its_original_host_and_keeps_its_lease
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.02)
    entered = Thread::Queue.new
    release = Thread::Queue.new
    closed = Thread::Queue.new
    owner = Rho::Runner::Extensions::Resources.new(extension: "waiting")
    owner.own { closed << true }
    context = Rho::Runner::ExecutionContext.new(deadline: now + 0.05)
    caller = Thread.new do
      capture_cancelled do
        pool.run(pool.reserve, context) do
          owner.acquire
          entered << Thread.current
          release.pop
          :late
        ensure
          owner.release
        end
      end
    end
    original = entered.pop(timeout: 2)
    refute_nil original
    refute owner.retire
    assert caller.join(2), "the caller should receive the deadline without waiting for the handler"
    assert_equal :deadline, caller.value.reason
    assert closed.empty?, "the still-live handler owns its extension lease"
    ticket = reserve_within(pool)
    refute_nil ticket
    assert_same original, pool.run(ticket, Rho::Runner::ExecutionContext.new) { Thread.current }
    release << true
    assert closed.pop(timeout: 2)
    assert closed.empty?, "the extension is released once at handler exit"
  ensure
    release << true if release
    caller&.join(2)
    pool&.stop
  end

  def test_one_unresponsive_host_is_replaced_once_and_its_other_contexts_are_canceled
    prior_threads = Thread.list
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.04)
    entered = Thread::Queue.new
    native_release = Thread::Queue.new
    closed = Thread::Queue.new
    deadline = now + 0.15
    contexts = [Rho::Runner::ExecutionContext.new(deadline: now + 3),
      Rho::Runner::ExecutionContext.new(deadline: deadline),
      Rho::Runner::ExecutionContext.new(deadline: deadline)]
    callers = []
    originals = []
    contexts.each_with_index do |context, index|
      ticket = reserve_within(pool)
      refute_nil ticket
      callers << Thread.new do
        capture_cancelled do
          pool.run(ticket, context) do
            entered << Thread.current
            if index == 2
              Fiber.blocking { native_release.pop }
            else
              loop do
                context.raise_if_cancelled!
                sleep 0.01
              end
            end
          ensure
            closed << index
          end
        end
      end
      originals << entered.pop(timeout: 2)
      refute_nil originals.last
    end
    assert_equal 1, originals.uniq.length
    callers.drop(1).each { |caller| assert caller.join(2), "a clamped caller remained blocked" }
    assert_equal :shutdown, contexts.first.reason, "retiring its host cancels the otherwise-live sibling"
    assert closed.empty?, "the original host has not yet exited any handler"

    replacements = 2.times.map do
      ticket = reserve_within(pool)
      refute_nil ticket
      pool.run(ticket, Rho::Runner::ExecutionContext.new) { Thread.current }
    end
    assert_equal 1, replacements.uniq.length, "simultaneous clamps cannot replace the same host twice"
    refute_same originals.first, replacements.first
    assert_equal 2, (Thread.list - prior_threads - callers).length,
      "only the blocked original and its one replacement remain"
    native_release << true
    callers.each { |caller| assert caller.join(2) }
    assert originals.first.join(2), "the retired host and its control fiber must finish"
    assert_equal [0, 1, 2], 3.times.map { closed.pop(timeout: 2) }.sort
    ticket = reserve_within(pool)
    refute_nil ticket
    assert_nil pool.reserve, "the original startup cannot return a second ticket after abandonment"
    assert_same replacements.first, pool.run(ticket, Rho::Runner::ExecutionContext.new) { Thread.current }
  ensure
    native_release << true if native_release
    contexts&.each { |context| context.cancel(:shutdown) }
    callers&.each { |caller| caller.join(2) }
    pool&.stop
  end

  def test_stop_cancels_waiting_handlers_and_exits_the_host_control_fibers
    pool = Rho::Runner::Pool.new(worker_threads: 2, grace_seconds: 0.05)
    entered = Thread::Queue.new
    callers = []
    execution_threads = []
    4.times do
      context = Rho::Runner::ExecutionContext.new
      ticket = reserve_within(pool)
      refute_nil ticket
      callers << Thread.new do
        capture_cancelled do
          pool.run(ticket, context) do
            release = Thread::Queue.new
            Rho::Runner::ExecutionContext.with_cancel_signal(-> { release << true }) do
              entered << Thread.current
              release.pop
              context.raise_if_cancelled!
            end
          end
        end
      end
      execution_threads << entered.pop(timeout: 2)
      refute_nil execution_threads.last
    end
    pool.stop
    callers.each do |caller|
      assert caller.join(2)
      assert_equal :shutdown, caller.value.reason
    end
    execution_threads.uniq.each { |thread| refute thread.alive? }
    assert_nil pool.reserve
    assert_raises(Rho::Runner::Pool::Stopped) do
      pool.run(Object.new, Rho::Runner::ExecutionContext.new) { flunk "stopped pool ran a handler" }
    end
  ensure
    pool&.stop
    callers&.each { |caller| caller.join(2) }
  end

  def test_stop_leaves_a_native_write_and_its_extension_lease_until_real_exit
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.02)
    entered = Thread::Queue.new
    native_release = Thread::Queue.new
    finish_write = Thread::Queue.new
    written = Thread::Queue.new
    closed = Thread::Queue.new
    owner = Rho::Runner::Extensions::Resources.new(extension: "writing")
    owner.own { closed << true }
    context = Rho::Runner::ExecutionContext.new(deadline: now + 1)
    caller = Thread.new do
      capture_cancelled do
        pool.run(pool.reserve, context) do
          owner.acquire
          entered << Thread.current
          Fiber.blocking { native_release.pop }
          written << :started
          finish_write.pop
          written << :complete
        ensure
          owner.release
        end
      end
    end
    original = entered.pop(timeout: 2)
    refute_nil original
    refute owner.retire
    stopped = Thread.new { pool.stop }
    assert stopped.join(1), "shutdown must return without interrupting the native write"
    assert_equal :shutdown, context.reason
    assert original.alive?, "shutdown must not kill a thread inside a write"
    assert written.empty?
    assert closed.empty?, "the live write still owns its extension lease"
    assert_nil pool.reserve
    native_release << true
    assert_equal :started, written.pop(timeout: 2)
    assert original.alive?, "retiring intake must preserve its waiting handler sibling"
    assert closed.empty?, "intake retirement must not release the live handler's lease"
    finish_write << true
    assert_equal :complete, written.pop(timeout: 2)
    assert closed.pop(timeout: 2)
    assert closed.empty?, "the extension must be released once at real exit"
    assert caller.join(2)
    assert original.join(2), "the stopped worker and its control fiber must exit"
  ensure
    native_release << true if native_release
    finish_write << true if finish_write
    caller&.join(2)
    stopped&.join(2)
    pool&.stop
  end

  private

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def capture_cancelled
      yield
    rescue Rho::Runner::ExecutionContext::Cancelled => error
      error
    end

    def assert_nested_work(workers:, parents:)
      pool = Rho::Runner::Pool.new(worker_threads: workers, grace_seconds: 0.05)
      requests = Thread::Queue.new
      closed = Thread::Queue.new
      seen = Thread::Queue.new
      contexts = Thread::Queue.new
      Async do |reactor|
        run = lambda do |level, path|
          context = Rho::Runner::ExecutionContext.new(task_key: path, deadline: now + 3)
          contexts << context
          owner = Rho::Runner::Extensions::Resources.new(extension: path)
          owner.own { closed << path }
          ticket = reserve_within(pool)
          refute_nil ticket, "nested work must find startup capacity while its parent waits"
          pool.run(ticket, context) do
            owner.acquire
            refute owner.retire
            seen << [path, Thread.current, Fiber.current]
            assert_same context, Rho::Runner::ExecutionContext.current
            held = 20
            answer = if level.zero?
              sleep 0.005
              2
            else
              response = Thread::Queue.new
              requests << Child.new(level: level - 1, path: "#{path}/child", answer: response)
              result = nil
              until result
                context.raise_if_cancelled!
                result = response.pop(timeout: 0.01)
              end
              held + result
            end
            assert_same context, Rho::Runner::ExecutionContext.current
            refute owner.disposed?, "the lease must span the entire live handler"
            answer
          ensure
            owner.release
          end
        end
        controller = reactor.async do
          while request = requests.pop
            reactor.async(request) { |_task, child| child.answer << run.call(child.level, child.path) }
          end
        end
        roots = parents.times.map { |index| reactor.async { run.call(2, index.to_s) } }
        assert_equal Array.new(parents, 42), roots.map(&:wait)
        requests.close
        controller.wait
      end.wait
      executions = Array.new(parents * 3) { seen.pop(timeout: 1) }
      assert_equal parents * 3, executions.map(&:first).uniq.length, "every handler started exactly once"
      assert_operator executions.map { |item| item[1] }.uniq.length, :<=, workers
      assert_equal parents * 3, executions.map { |item| item[2] }.uniq.length
      assert_equal executions.map(&:first).sort, Array.new(parents * 3) { closed.pop(timeout: 1) }.sort
      assert_equal 0, pool.in_flight
    ensure
      contexts&.close
      while context = contexts&.pop
        context.cancel(:shutdown)
      end
      requests&.close
      pool&.stop
    end

    def reserve_within(pool, seconds: 1)
      deadline = now + seconds
      loop do
        ticket = pool.reserve
        return ticket if ticket
        return nil if now >= deadline

        sleep 0.001
      end
    end
end
