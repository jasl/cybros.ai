require "test_helper"
# Kernel#Sync comes with the async gem, which loads lazily with the runner
# host — the reactor-timer pins here need it regardless of test order.
require "async"

# The coalescing window's ownership under the reactor, driven on a narration double whose append has
# the durable sink's SHAPE — one round trip (a reactor tick), then the running gate — so the fiber
# order is the test's to choose, never the database's. The race: the last text_delta opens a window,
# the timer takes it, `response.completed` lands inside the timer's round trip, the settle finds
# nothing pending, ApplyResult commits the terminal status, and the timer's gated append is refused.
# The reply then lacks its last window while `result` still lands.
class ModelInvocations::DeltaCoalescingTest < ActiveSupport::TestCase
  KEY = [:text].freeze

  # A sink whose store is a list: `landed` is what committed while the
  # invocation was running, `dropped` what the gate refused after the
  # terminal flip. `taken` fires as an append enters its round trip.
  class Narration
    include ModelInvocations::DeltaCoalescing

    attr_reader :landed, :dropped, :taken

    def initialize(**coalescing)
      @landed = []
      @dropped = []
      @terminal = false
      @taken = Async::Condition.new
      initialize_delta_coalescing(**coalescing)
    end

    # ApplyResult's terminal commit, in the shape the gate reads.
    def terminalize! = @terminal = true

    private

      def append_coalesced_delta(_key, text)
        @taken.signal
        # The one round trip between taking the buffer and committing it.
        Async::Task.current.yield
        (@terminal ? @dropped : @landed) << text
      end
  end

  test "the settle owns a timer flush in flight: the last window lands before the terminal commit" do
    sink = Narration.new(flush_interval_ms: 10, clock: -> { 0.0 })

    Sync do |task|
      sink.coalesce_delta(KEY, "lead")
      sink.coalesce_delta(KEY, " tail")
      # The timer fires and takes the buffer; its append is mid round trip.
      sink.taken.wait
      # `response.completed`: the settle, then ApplyResult's commit — the
      # order ExecuteAttempt runs them in.
      sink.flush_pending_delta
      sink.terminalize!
      # The timer's round trip returns.
      task.yield
    end

    assert_equal "lead tail", sink.landed.join,
      "the settle found nothing pending and the timer's append was refused after the flip"
    assert_empty sink.dropped
  end

  test "a fragment arriving during a timer flush in flight lands after it" do
    sink = Narration.new(flush_interval_ms: 10, clock: -> { 0.0 })

    Sync do |task|
      sink.coalesce_delta(KEY, "one")
      sink.coalesce_delta(KEY, " two")
      sink.taken.wait
      sink.coalesce_delta(KEY, " three")
      sink.flush_pending_delta
      task.yield
    end

    assert_equal ["one", " two", " three"], sink.landed,
      "the in-flight window commits before the fragment after it is placed"
  end

  test "a retry joins a timer flush in flight, so its rollback marker follows the delta" do
    sink = Narration.new(flush_interval_ms: 10, clock: -> { 0.0 })

    Sync do |task|
      sink.coalesce_delta(KEY, "lead")
      sink.coalesce_delta(KEY, " tail")
      sink.taken.wait
      # on_retry: abandon the window, then the rollback marker.
      sink.abandon_pending_delta
      sink.landed << :rollback
      task.yield
    end

    assert_equal ["lead", " tail", :rollback], sink.landed,
      "the marker committed before the delta it was meant to roll back"
  end

  test "a cancel discards without waiting: the timer's append lands or is refused on its own" do
    sink = Narration.new(flush_interval_ms: 10, clock: -> { 0.0 })

    Sync do |task|
      sink.coalesce_delta(KEY, "lead")
      sink.coalesce_delta(KEY, " tail")
      sink.taken.wait
      sink.discard_pending_delta
      sink.terminalize!
      task.yield
    end

    assert_equal ["lead"], sink.landed
    assert_equal [" tail"], sink.dropped, "the abort path put no wait in front of the terminal flip"
  end

  test "a synchronous flush the timer wakes into is left to the pump" do
    sink = Narration.new(flush_interval_ms: 10, clock: -> { 0.0 })

    Sync do |task|
      sink.coalesce_delta(KEY, "lead")
      sink.coalesce_delta(KEY, " tail")
      # The pump flushes first (a key switch, an aged buffer, the settle),
      # and its round trip is where the timer wakes.
      flushing = task.async { sink.flush_pending_delta }
      sleep(0.05)
      flushing.wait
    end

    assert_equal ["lead", " tail"], sink.landed, "the window commits once"
  end
end
