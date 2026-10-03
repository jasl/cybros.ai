require "test_helper"
require "support"

class SessionPopupsTest < Minitest::Test
  def setup
    @now = 0.0
    @driver = BrowserTest::FakeDriver.new
    @session = Rho::Browser::Session.new(
      driver: @driver, idle_after: 60.0, clock: -> { @now }, call_deadline: 0.1
    )
  end

  def teardown = @session.close

  def test_idle_reclamation_closes_descendants_and_keeps_another_loops_popups
    idle = @session.with_page("idle") { |page| page }
    child = popup(idle)
    grandchild = popup(child)
    @now = 61.0
    active = @session.with_page("active") { |page| page }
    other_child = popup(active)
    other_grandchild = popup(other_child)

    @session.send(:look_for_idle)

    [idle, child, grandchild].each { |page| assert_predicate page, :closed? }
    [active, other_child, other_grandchild].each { |page| refute_predicate page, :closed? }
    assert_equal 1, @session.tab_count
    assert_equal 0, @driver.stops
  end

  def test_a_timed_out_call_releases_its_popups_without_resetting_other_loops
    failed = @session.with_page("failed") { |page| page }
    child = popup(failed)
    grandchild = popup(child)
    active = @session.with_page("active") { |page| page }
    other_child = popup(active)

    assert_raises(Rho::Browser::CallTimedOut) { @session.with_page("failed") { sleep } }

    [failed, child, grandchild].each { |page| assert_predicate page, :closed? }
    [active, other_child].each { |page| refute_predicate page, :closed? }
    assert_equal 0, @driver.stops
    @session.with_page("failed") { |page, fresh| refute_same failed, page; assert fresh }
  end

  def test_a_page_that_closed_itself_leaves_no_orphans_after_replacement
    closed = @session.with_page("returned") { |page| page }
    child = popup(closed)
    grandchild = popup(child)
    closed.close
    replacement = @session.with_page("returned") { |page| page }
    replacement_child = popup(replacement)
    active = @session.with_page("active") { |page| page }
    other_child = popup(active)

    @session.send(:look_for_idle)

    [child, grandchild].each { |page| assert_predicate page, :closed? }
    [replacement, replacement_child, active, other_child].each { |page| refute_predicate page, :closed? }
    assert_equal 2, @session.tab_count
    assert_equal 0, @driver.stops
  end

  def test_a_popup_arriving_while_its_owner_closes_is_reclaimed_in_the_same_sweep
    idle = @session.with_page("idle") { |page| page }
    late = nil
    create_popup = -> { late = popup(idle) }
    idle.define_singleton_method(:close) do
      close!
      create_popup.call
    end
    @now = 61.0
    active = @session.with_page("active") { |page| page }
    other_child = popup(active)

    @session.send(:look_for_idle)

    refute_nil late
    assert_predicate late, :closed?
    refute_predicate other_child, :closed?
    assert_equal 0, @driver.stops
  end

  def test_an_opening_main_page_is_not_collected_before_it_is_registered
    @session.with_page("active") { |_page| }
    entered = Queue.new
    release = Queue.new
    @driver.define_singleton_method(:new_page) do
      page = super()
      entered << page
      release.pop
      page
    end
    caller = Thread.new { @session.with_page("arriving") { |page| page } }
    page = entered.pop(timeout: 2) || flunk("the new page never opened")
    @session.send(:look_for_idle)
    refute_predicate page, :closed?
    release << true
    caller.join(2) || flunk("the new page never reached its owner")
    assert_same page, caller.value
    @session.send(:look_for_idle)
    refute_predicate page, :closed?
  ensure
    release << true
    caller&.join(2)
  end

  def test_an_orphan_that_cannot_close_uses_the_existing_bounded_driver_recovery
    closed = @session.with_page("closed") { |page| page }
    child = popup(closed)
    def child.close = sleep
    closed.close
    @session.with_page("active") { |_page| }

    reaper = Thread.new { @session.send(:look_for_idle) }
    reaper.join(5) || flunk("orphan cleanup never returned")

    assert_equal 1, @driver.stops
    assert_empty @driver.open_pages
    @session.with_page("active") { |_page, fresh| assert fresh }
  ensure
    reaper&.join(1)
  end

  private

    def popup(opener)
      BrowserTest::FakePage.new.tap do |page|
        page.opener = opener
        @driver.pages << page
      end
    end
end
