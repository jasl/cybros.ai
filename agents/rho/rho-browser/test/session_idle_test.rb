require "test_helper"
require "support"

class SessionIdleTest < Minitest::Test
  def setup
    @now = 0.0
    @driver = BrowserTest::FakeDriver.new
    @session = Rho::Browser::Session.new(
      driver: @driver, idle_after: 60.0, clock: -> { @now }, call_deadline: 5.0
    )
  end

  def teardown = @session.close

  def sweep = @session.send(:look_for_idle)

  def test_continuous_new_loops_retain_only_recent_tabs
    100.times do |i|
      @now = i.to_f
      @session.with_page("loop-#{i}") { |page| page.goto("https://example.test/#{i}") }
      sweep
    end

    assert_equal 60, @session.tab_count
    assert_equal 40, @driver.pages.count(&:closed?)
    assert_equal 1, @driver.starts
    assert_equal 0, @driver.stops, "ongoing work must keep the shared browser"
  end

  def test_an_expired_owner_returns_to_a_new_tab_and_is_told_once
    original = @session.with_page("idle") { |page| page }
    @now = 61.0
    active = @session.with_page("active") { |page| page }
    sweep

    assert_predicate original, :closed?
    refute_predicate active, :closed?
    @session.with_page("idle") do |page, fresh|
      refute_same original, page
      assert fresh, "earlier snapshot refs no longer name this page"
    end
    @session.with_page("idle") { |_page, fresh| refute fresh }
    @session.with_page("active") { |page, fresh| assert_same active, page; refute fresh }
  end

  def test_an_in_flight_tab_does_not_prevent_other_idle_tabs_from_closing
    idle = @session.with_page("idle") { |page| page }
    entered = Queue.new
    release = Queue.new
    held = Thread.new do
      @session.with_page("held") do |page|
        entered << page
        release.pop
      end
    end
    active = entered.pop(timeout: 2) || flunk("the browser call did not start")
    @now = 61.0
    sweep

    assert_predicate idle, :closed?
    refute_predicate active, :closed?
    assert_equal 0, @driver.stops
    release << true
    held.join(2) || flunk("the browser call did not finish")
    sweep
    refute_predicate active, :closed?, "idle time must start when the call finishes"
  ensure
    release << true
    held&.join(2)
  end

  def test_closing_an_idle_page_does_not_hold_the_registry
    idle = @session.with_page("idle") { |page| page }
    @now = 61.0
    @session.with_page("active") { |_page| }
    closing = Queue.new
    release = Queue.new
    idle.define_singleton_method(:close) do
      closing << true
      release.pop
      close!
    end
    reaper = Thread.new { sweep }
    refute_nil closing.pop(timeout: 2), "the idle page was never closed"
    called = Queue.new
    caller = Thread.new { @session.with_page("other") { |page| called << page } }
    refute_nil called.pop(timeout: 2), "page.close held the registry and blocked another loop"
  ensure
    release << true
    reaper&.join(4)
    caller&.join(2)
  end

  def test_all_idle_tabs_are_released_with_one_driver_stop
    3.times { |i| @session.with_page("loop-#{i}") { |_page| } }
    @now = 61.0

    assert_equal :gone, sweep
    assert_equal 0, @session.tab_count
    assert_equal 1, @driver.stops
    assert_empty @driver.pages.flat_map(&:calls), "whole-browser idle needs no per-page close"
  end

  def test_a_tab_used_after_the_reaper_takes_its_snapshot_is_kept
    first = @session.with_page("first") { |page| page }
    second = @session.with_page("second") { |page| page }
    @now = 61.0
    @session.with_page("active") { |_page| }
    closing = Queue.new
    release = Queue.new
    first.define_singleton_method(:close) do
      closing << true
      release.pop
      close!
    end
    reaper = Thread.new { sweep }
    refute_nil closing.pop(timeout: 2), "the reaper never started closing its candidates"

    @session.with_page("second") { |page| assert_same second, page }
    release << true
    reaper.join(4) || flunk("the reaper never finished")
    assert_predicate first, :closed?
    refute_predicate second, :closed?, "the reaper used a stale idle timestamp"
  ensure
    release << true
    reaper&.join(4)
  end

  def test_the_next_call_for_a_tab_being_closed_waits_for_its_replacement
    idle = @session.with_page("idle") { |page| page }
    @now = 61.0
    @session.with_page("active") { |_page| }
    closing = Queue.new
    release = Queue.new
    idle.define_singleton_method(:close) do
      closing << true
      release.pop
      close!
    end
    reaper = Thread.new { sweep }
    refute_nil closing.pop(timeout: 2), "the idle page was never closed"
    called = Queue.new
    caller = Thread.new { @session.with_page("idle") { |page, fresh| called << [page, fresh] } }
    assert_nil called.pop(timeout: 0.05), "a call used a page while it was being closed"
    release << true
    page, fresh = called.pop(timeout: 2) || flunk("the waiting call did not resume")
    refute_same idle, page
    assert fresh
    assert_equal 1, @driver.starts
  ensure
    release << true
    reaper&.join(4)
    caller&.join(2)
  end

  def test_a_tab_replaced_after_the_reaper_takes_its_snapshot_is_kept
    first = @session.with_page("first") { |page| page }
    stale = @session.with_page("second") { |page| page }
    @now = 61.0
    @session.with_page("active") { |_page| }
    closing = Queue.new
    release = Queue.new
    first.define_singleton_method(:close) do
      closing << true
      release.pop
      close!
    end
    reaper = Thread.new { sweep }
    refute_nil closing.pop(timeout: 2), "the reaper never started closing its candidates"

    stale.close!
    replacement = @session.with_page("second") { |page| page }
    refute_same stale, replacement
    release << true
    reaper.join(4) || flunk("the reaper never finished")
    refute_predicate replacement, :closed?
    @session.with_page("second") { |page, fresh| assert_same replacement, page; refute fresh }
  ensure
    release << true
    reaper&.join(4)
  end

  def test_an_idle_page_that_cannot_close_restarts_the_driver_on_a_clock
    idle = @session.with_page("idle") { |page| page }
    def idle.close = sleep
    @now = 61.0
    @session.with_page("active") { |_page| }
    reaper = Thread.new { sweep }
    reaper.join(5) || flunk("closing an idle page never returned")

    assert_equal 1, @driver.stops
    assert_equal 0, @session.tab_count
    @session.with_page("active") { |_page, fresh| assert fresh }
    assert_equal 2, @driver.starts
  ensure
    reaper&.join(1)
  end

  def test_a_cancelled_first_call_keeps_the_new_tab_notice
    context = Rho::Runner::ExecutionContext.new
    Rho::Runner::ExecutionContext.with(context) do
      assert_raises(Rho::Runner::ExecutionContext::Cancelled) do
        @session.with_page("new") do |_page, fresh|
          assert fresh
          context.cancel
          context.raise_if_cancelled!
        end
      end
    end
    @session.with_page("new") { |_page, fresh| assert fresh }
    @session.with_page("new") { |_page, fresh| refute fresh }
  end
end
