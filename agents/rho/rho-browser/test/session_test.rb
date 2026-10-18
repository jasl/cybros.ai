require "test_helper"
require "support"

# THE SUPERVISOR: what holding one browser for a whole daemon actually
# requires, stated as tests rather than as a comment nobody runs — and,
# since the first review, with a clock on every path, not just the call.
class SessionTest < Minitest::Test
  include BrowserTest::Helpers

  FAST = { call_deadline: 0.3, start_deadline: 0.3, stop_deadline: 0.3, close_wait: 0.2,
           lock_wait: 0.5, tab_wait: 0.5 }.freeze

  def session(driver = BrowserTest::FakeDriver.new, **over)
    [Rho::Browser::Session.new(driver: driver, **FAST, **over), driver]
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def test_nothing_starts_until_a_page_is_asked_for
    s, driver = session
    refute_predicate s, :started?
    assert_equal 0, driver.starts
  end

  def test_the_first_call_starts_and_later_calls_reuse
    s, driver = session
    with_tool_env { 3.times { s.with_page { |page| page.goto("http://x") } } }
    assert_equal 1, driver.starts
    assert_predicate s, :started?
  end

  # A start that fails must leave NOTHING behind: the next call tries
  # again instead of inheriting a poisoned handle.
  def test_a_failed_start_is_retried_on_the_next_call
    s, driver = session(BrowserTest::FakeDriver.new(fail_starts: 1))
    with_tool_env do
      assert_raises(RuntimeError) { s.with_page { |_page| } }
      refute_predicate s, :started?
      s.with_page { |page| assert_equal driver.page, page }
    end
    assert_equal 2, driver.starts
  end

  # A crashed tab is this loop's problem, not the browser's: the tab is
  # replaced, the driver keeps running, and the next call is told.
  def test_a_dead_page_is_replaced_by_a_new_tab_and_the_owner_is_told
    page = BrowserTest::FakePage.new
    s, driver = session(BrowserTest::FakeDriver.new(page: page))
    with_tool_env do
      s.with_page { |_p, fresh| assert fresh }
      page.close!
      s.with_page do |p, reset|
        refute_same page, p
        assert reset, "the owner was not told its tab was replaced"
      end
      s.with_page { |_p, reset| refute reset, "the notice must be given once" }
    end
    assert_equal 1, driver.starts
    assert_equal 0, driver.stops
    assert_equal 2, driver.pages.size
  end

  # A driver that died while nobody was calling — crashed, OOM-killed —
  # is known to the driver before any page would tell, and replaced; every
  # owner's next call is told.
  def test_a_driver_that_died_idle_is_replaced_on_the_next_call
    s, driver = session
    with_tool_env do
      s.with_page("loop-a") { |_p| }
      s.with_page("loop-b") { |_p| }
      driver.die!
      s.with_page("loop-a") { |_p, reset| assert reset }
      s.with_page("loop-b") { |_p, reset| assert reset }
    end
    assert_equal 2, driver.starts
    assert_equal 1, driver.stops
  end

  # A tool's own inner timeout is never mistaken for the session's: only
  # the session's Deadline restarts the driver.
  def test_an_inner_timeout_error_is_not_the_sessions_ceiling
    s, driver = session
    with_tool_env do
      assert_raises(Timeout::Error) { s.with_page { |_p| raise Timeout::Error, "inner" } }
    end
    assert_equal 0, driver.stops, "a healthy driver was restarted for a tool's own timeout"
  end

  def test_calls_are_serialized
    s, = session
    inside = 0
    overlap = false
    threads = Array.new(4) do
      Thread.new do
        Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
          5.times do
            s.with_page do |_page|
              inside += 1
              overlap = true if inside > 1
              sleep 0.001
              inside -= 1
            end
          end
        end
      end
    end
    threads.each(&:join)
    refute overlap, "two calls were inside the session at once"
  end

  def test_cancellation_is_honoured_before_the_lock_and_after
    s, driver = session
    context = Rho::Runner::ExecutionContext.new
    context.cancel
    Rho::Runner::ExecutionContext.with(context) do
      assert_raises(Rho::Runner::ExecutionContext::Cancelled) { s.with_page { |_p| } }
    end
    assert_equal 0, driver.starts, "a cancelled task must not start a browser"
  end

  # A task cancelled WHILE another call holds the browser must give up at
  # once, not when the holder is done and not at its own park deadline —
  # which means the wait for the lock polls, and checks.
  def test_a_waiter_sees_its_cancellation_while_another_call_holds_the_browser
    s, = session
    entered = Queue.new
    release = Queue.new
    holder = Thread.new do
      Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
        s.with_page do |_p|
          entered << true
          release.pop
        end
      end
    end
    entered.pop

    context = Rho::Runner::ExecutionContext.new
    waiter = Thread.new do
      # The raise is the point of the test; the thread need not report it.
      Thread.current.report_on_exception = false
      Rho::Runner::ExecutionContext.with(context) do
        s.with_page { |_p| }
      end
    end
    sleep 0.05
    context.cancel
    error = assert_raises(Rho::Runner::ExecutionContext::Cancelled) { waiter.join(2) || flunk("waiter never returned"); waiter.value }
    assert_kind_of Rho::Runner::ExecutionContext::Cancelled, error
  ensure
    release << true
    holder&.join(1)
  end

  # And a waiter that is not cancelled still does not wait forever: the
  # ceiling is read off the session's clock, advanced here by a fifth of
  # the wait per read, so the pin costs polls rather than seconds.
  def test_the_wait_for_the_lock_has_its_own_ceiling
    now = 0.0
    s, = session(tab_wait: 0.2, clock: -> { now += 0.04 })
    entered = Queue.new
    release = Queue.new
    holder = Thread.new do
      Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
        s.with_page do |_p|
          entered << true
          release.pop
        end
      end
    end
    entered.pop
    with_tool_env do
      error = assert_raises(Rho::Browser::CallTimedOut) { s.with_page { |_p| } }
      assert_match(/still running/, error.message)
    end
  ensure
    release << true
    holder&.join(1)
  end

  def test_close_is_idempotent_and_refuses_later_calls
    s, driver = session
    with_tool_env { s.with_page { |_p| } }
    s.close
    s.close
    assert_equal 1, driver.stops
    with_tool_env { assert_raises(Rho::Browser::Closed) { s.with_page { |_p| } } }
    assert_equal 1, driver.starts, "a closed session must not restart"
  end

  def test_close_before_any_start_stops_nothing
    s, driver = session
    s.close
    assert_equal 0, driver.stops
  end

  # THE TWO VERDICTS. A call that never returns is cut at the ceiling;
  # if the transport still speaks, only THIS loop's tab is dropped and
  # the other loop never notices; the owner is told on its next call.
  def test_a_call_that_never_returns_on_a_live_driver_drops_only_its_own_tab
    page = BrowserTest::FakePage.new
    def page.goto(_url) = sleep
    driver = BrowserTest::FakeDriver.new(page: page)
    s, = session(driver)

    with_tool_env do
      s.with_page("loop-a") { |p| assert_same page, p, "the shaped page must be loop-a's" }
      s.with_page("loop-b") { |_p| }
      took = elapsed do
        error = assert_raises(Rho::Browser::CallTimedOut) do
          s.with_page("loop-a") { |p| p.goto("http://x") }
        end
        assert_match(/this loop's tab was reset/, error.message)
      end
      assert_operator took, :<, 3.0
      assert_predicate page, :closed?, "the wedged tab was not closed"
      assert_equal 0, driver.stops, "a live driver was restarted for one loop's stuck page"
      assert_equal 1, s.tab_count, "the other loop's tab was dropped too"

      s.with_page("loop-a") { |p, reset| assert reset; refute_same page, p }
      s.with_page("loop-b") { |_p, reset| refute reset, "the other loop was told of a reset it did not have" }
    end
  end

  # ...and if even CLOSING the tab does not return on a clock, it is the
  # driver's failure: stopped, and every loop is told. (Not a `title`
  # probe: that asks the wedged page's own renderer, which is exactly
  # what cannot answer, and would call a busy page a dead driver.)
  def test_a_call_that_never_returns_on_a_silent_transport_restarts_the_driver
    page = BrowserTest::FakePage.new
    def page.goto(_url) = sleep
    def page.close = sleep
    driver = BrowserTest::FakeDriver.new(page: page)
    s, = session(driver)

    with_tool_env do
      s.with_page("loop-a") { |p| assert_same page, p }
      s.with_page("loop-b") { |_p| }
      error = assert_raises(Rho::Browser::CallTimedOut) { s.with_page("loop-a") { |p| p.goto("http://x") } }
      assert_match(/this loop's tab was reset/, error.message)
      assert_equal 1, driver.stops, "a tab that cannot be closed must escalate to the driver"
      assert_equal 0, s.tab_count
      assert_equal 1, driver.stops
      assert_equal 0, s.tab_count
      s.with_page("loop-b") { |_p, reset| assert reset, "the other loop was not told the browser restarted" }
    end
    assert_equal 2, driver.starts
  end

  # DIFFERENT LOOPS RUN CONCURRENTLY; the same loop serializes.
  def test_two_loops_run_at_once_on_their_own_tabs
    s, driver = session(call_deadline: 5.0)
    a_inside = Queue.new
    release = Queue.new
    holder = Thread.new do
      Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
        s.with_page("loop-a") do |_p|
          a_inside << true
          release.pop
        end
      end
    end
    a_inside.pop

    took = elapsed { with_tool_env { s.with_page("loop-b") { |_p| } } }
    assert_operator took, :<, 1.0, "loop-b waited on loop-a's tab"
    assert_equal 2, driver.pages.size
  ensure
    release << true
    holder&.join(1)
  end

  def test_a_second_call_from_the_same_loop_waits_and_the_message_says_so
    s, = session(tab_wait: 0.2, call_deadline: 5.0)
    entered = Queue.new
    release = Queue.new
    holder = Thread.new do
      Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
        s.with_page("loop-a") do |_p|
          entered << true
          release.pop
        end
      end
    end
    entered.pop
    with_tool_env do
      error = assert_raises(Rho::Browser::CallTimedOut) { s.with_page("loop-a") { |_p| } }
      assert_match(/an earlier browser call from this task is still running/, error.message)
    end
  ensure
    release << true
    holder&.join(1)
  end

  # THE GENERATION CHECK: two loops fail on the same dead driver; the
  # first recovery stops it, the second finds a successor and does NOT.
  def test_a_stale_recovery_never_stops_the_successor_driver
    page_a = BrowserTest::FakePage.new
    driver = BrowserTest::FakeDriver.new(page: page_a)
    s, = session(driver)
    with_tool_env do
      s.with_page("loop-a") { |_p| }
      s.with_page("loop-b") { |_p| }
    end
    driver.die!
    # loop-a's call fails on the dead driver and restarts it...
    with_tool_env do
      assert_raises(RuntimeError) { s.with_page("loop-a") { |_p| raise "dead" } }
    end
    assert_equal 1, driver.stops
    assert_equal 2, driver.starts
    # ...a later call for loop-b, born under generation 0, gets a fresh tab
    # on the successor and never stops it.
    with_tool_env { s.with_page("loop-b") { |_p, reset| assert reset } }
    assert_equal 1, driver.stops, "a stale verdict stopped the successor driver"
  end

  # THE FIRST REVIEW'S FINDING, as a unit: the clock covers the START and
  # the STOP, not only the call. A driver that never finishes starting is
  # cut; a driver that never finishes stopping is abandoned on a clock,
  # and neither holds the lock past its bound.
  def test_a_start_that_never_returns_is_cut_at_the_start_ceiling
    s, = session(BrowserTest::FakeDriver.new(hang_start: true))
    with_tool_env do
      took = elapsed do
        error = assert_raises(Rho::Browser::CallTimedOut) { s.with_page { |_p| } }
        assert_match(/starting the browser exceeded/, error.message)
      end
      assert_operator took, :<, 2.0
    end
  end

  def test_a_stop_that_never_returns_does_not_hold_the_session
    driver = BrowserTest::FakeDriver.new(hang_stop: true)
    s, = session(driver)
    with_tool_env { s.with_page { |_p| } }
    took = elapsed { s.close }
    assert_operator took, :<, 2.0, "close hung on a driver that would not stop"
    assert_equal 1, driver.stops
  end

  def test_a_stop_that_never_returns_after_a_timed_out_call_does_not_wedge_the_next_call
    page = BrowserTest::FakePage.new
    def page.goto(_url) = sleep
    driver = BrowserTest::FakeDriver.new(page: page, hang_stop: true)
    s, = session(driver)
    with_tool_env do
      took = elapsed do
        assert_raises(Rho::Browser::CallTimedOut) { s.with_page { |p| p.goto("http://x") } }
      end
      assert_operator took, :<, 2.0, "the timed-out call's recovery hung on the driver's stop"
    end
  end

  # An ordinary page error keeps the browser: the page is probed, answers,
  # and is handed to the next call as it was.
  def test_a_page_error_does_not_restart_a_live_browser
    s, driver = session
    with_tool_env do
      assert_raises(RuntimeError) { s.with_page { |_p| raise "no such ref" } }
      s.with_page { |_p| }
    end
    assert_equal 1, driver.starts
    assert_equal 0, driver.stops
  end

  # But an error on a driver whose PROCESS is gone is the driver's: it
  # is restarted, and the owner is told.
  def test_a_page_error_on_a_dead_driver_restarts
    s, driver = session
    with_tool_env do
      assert_raises(RuntimeError) do
        s.with_page do |_p|
          driver.die!
          raise "driver went away"
        end
      end
      s.with_page { |_p, reset| assert reset }
    end
    assert_equal 1, driver.stops
    assert_equal 2, driver.starts
  end

  # The daemon's drain must not hang on a page waiting for a network that
  # will never answer: close waits, on a bound, and then stops anyway —
  # keyed on the driver, so a start still in flight is stopped too.
  def test_close_does_not_wait_forever_for_a_wedged_call_and_still_stops_the_driver
    driver = BrowserTest::FakeDriver.new
    s, = session(driver)
    entered = Queue.new
    release = Queue.new
    holder = Thread.new do
      Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
        s.with_page do |_p|
          entered << true
          release.pop
        end
      end
    end
    entered.pop

    took = elapsed { s.close }
    assert_operator took, :<, 2.0, "close waited past its bound"
    assert_equal 1, driver.stops, "the driver was not stopped despite the holder"
  ensure
    release << true
    holder&.join(1)
  end

  # IDLE REAPING: a browser nobody has touched is closed, by a thread that
  # lives only while a browser does; the next call starts a fresh one.
  def until_true(seconds = 2.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    yield
  end

  def test_no_reaper_runs_before_a_browser_starts
    s, = session(idle_after: 0.1)
    refute_predicate s, :reaping?
  end

  def test_an_idle_browser_is_closed_and_the_next_call_starts_a_fresh_one
    s, driver = session(idle_after: 0.1)
    with_tool_env { s.with_page { |_p| } }
    assert_predicate s, :reaping?

    assert until_true { driver.stops == 1 }, "the idle browser was never reaped"
    refute_predicate s, :started?
    assert until_true { !s.reaping? }, "the reaper outlived the browser it watched"

    with_tool_env { s.with_page { |_p| } }
    assert_equal 2, driver.starts
    assert_predicate s, :reaping?, "a fresh browser gets a fresh reaper"
  end

  # A call in progress is by definition not idle: the reaper takes the
  # lock only if it is free, and a browser is never closed out from under
  # the thread using it.
  def test_a_browser_in_use_is_never_reaped
    # The hold below outlasts FAST's call ceiling on purpose, so the
    # ceiling must be raised here — otherwise the CALL deadline discards
    # the driver and reads as a reap.
    s, driver = session(idle_after: 0.1, call_deadline: 5.0)
    entered = Queue.new
    release = Queue.new
    holder = Thread.new do
      Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
        s.with_page do |_p|
          entered << true
          release.pop
        end
      end
    end
    entered.pop
    sleep 0.4
    assert_equal 0, driver.stops, "reaped a browser a call was using"
    release << true
    holder.join(1)
    # Used just now, so not idle yet — then idle, then gone.
    assert_equal 0, driver.stops
    assert until_true { driver.stops == 1 }
  end

  def test_close_wakes_the_reaper_and_it_exits_at_once
    s, driver = session(idle_after: 60.0)
    with_tool_env { s.with_page { |_p| } }
    assert_predicate s, :reaping?
    took = elapsed { s.close }
    assert_operator took, :<, 2.0, "close waited out a reaper tick"
    refute_predicate s, :reaping?
    assert_equal 1, driver.stops
  end

  # BROWSER GONE, NODE ALIVE. The OOM killer takes Chromium and leaves the
  # driver process; opening a tab then fails. That is the driver's
  # failure — restarted at once, not ten minutes later by the reaper.
  def test_a_browser_that_died_under_a_live_driver_is_restarted_on_the_next_call
    driver = BrowserTest::FakeDriver.new
    s, = session(driver)
    with_tool_env { s.with_page("loop-a") { |_p| } }
    def driver.new_page = raise("Target page, context or browser has been closed")
    with_tool_env do
      error = assert_raises(Rho::Browser::CallTimedOut) { s.with_page("loop-b") { |_p| } }
      assert_match(/could not open a tab .*restarted/, error.message)
    end
    assert_equal 1, driver.stops
    driver.singleton_class.remove_method(:new_page)
    with_tool_env { s.with_page("loop-a") { |_p, reset| assert reset } }
    assert_equal 2, driver.starts
  end

  # A tab whose page closed UNDER a call in flight is not retired out from
  # under its holder; the same loop's next call waits for it instead.
  def test_a_held_tab_is_never_retired_by_a_sibling_call
    page = BrowserTest::FakePage.new
    driver = BrowserTest::FakeDriver.new(page: page)
    s, = session(driver, tab_wait: 0.3, call_deadline: 5.0)
    entered = Queue.new
    release = Queue.new
    holder = Thread.new do
      Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
        s.with_page("loop-a") do |_p|
          entered << true
          release.pop
        end
      end
    end
    entered.pop
    page.close!
    with_tool_env do
      assert_raises(Rho::Browser::CallTimedOut) { s.with_page("loop-a") { |_p| } }
    end
    assert_equal 1, driver.pages.size, "a second tab was opened for a loop whose tab was held"
  ensure
    release << true
    holder&.join(1)
  end

  # The notice survives a first call that fails, and a call that was
  # cancelled before it delivered anything.
  def test_the_reset_notice_is_not_lost_to_a_failing_or_cancelled_call
    page = BrowserTest::FakePage.new
    driver = BrowserTest::FakeDriver.new(page: page)
    s, = session(driver)
    with_tool_env do
      s.with_page("loop-a") { |_p| }
      page.close!
      # consumed by a call that raises...
      seen = nil
      assert_raises(RuntimeError) { s.with_page("loop-a") { |_p, reset| seen = reset; raise "dns" } }
      assert seen, "the failing call did not see the reset"
    end
    # ...a cancelled call re-arms it...
    context = Rho::Runner::ExecutionContext.new
    Rho::Runner::ExecutionContext.with(context) do
      assert_raises(Rho::Runner::ExecutionContext::Cancelled) do
        s.with_page("loop-a") do |_p, _reset|
          context.cancel
          context.raise_if_cancelled!
        end
      end
    end
    with_tool_env do
      s.with_page("loop-a") { |_p, reset| refute reset, "a delivered notice was repeated" }
    end
  end

  def test_the_idle_clock_is_stamped_at_start_even_if_the_first_tab_fails
    driver = BrowserTest::FakeDriver.new
    def driver.new_page = raise("no tab")
    s, = session(driver, idle_after: 5.0)
    with_tool_env { assert_raises(Rho::Browser::CallTimedOut) { s.with_page { |_p| } } }
    # the driver was stopped by the failed tab; nothing idle-looking is left
    refute_predicate s, :started?
  end

  # A call cancelled INSIDE its own recovery — waiting for a registry
  # another loop holds — still owes the new tab notice it consumed.
  # The registry is taken AFTER the call acquired its tab
  # (signalled from the page) and before its recovery reaches it.
  def test_a_call_cancelled_during_recovery_re_arms_the_notice
    entered = Queue.new
    page = BrowserTest::FakePage.new
    page.define_singleton_method(:goto) { |_url| entered << true; sleep }
    driver = BrowserTest::FakeDriver.new(page: page)
    s, = session(driver, call_deadline: 0.1)
    registry = s.instance_variable_get(:@registry)
    context = Rho::Runner::ExecutionContext.new
    caller = Thread.new do
      Thread.current.report_on_exception = false
      Rho::Runner::ExecutionContext.with(context) { s.with_page("loop-a") { |p, reset| assert reset; p.goto("x") } }
    end
    refute_nil entered.pop(timeout: 5), "the call never reached the page"
    registry.lock
    sleep 0.3
    context.cancel
    error = begin
      caller.join(5) || flunk("the cancelled call never returned")
      caller.value
    rescue Exception => e # rubocop:disable Lint/RescueException
      e
    end
    registry.unlock
    assert_kind_of Rho::Runner::ExecutionContext::Cancelled, error
    with_tool_env { s.with_page("loop-a") { |_p, reset| assert reset, "the cancelled call lost the notice" } }
  end

  def test_a_gem_nil_value_error_is_described_not_quoted
    driver = BrowserTest::FakeDriver.new
    def driver.new_page = nil.value!
    s, = session(driver)
    with_tool_env do
      error = assert_raises(Rho::Browser::CallTimedOut) { s.with_page { |_p| } }
      assert_match(/the browser connection was already closed/, error.message)
      refute_match(/value!/, error.message)
    end
  end
end
