require "test_helper"
require "cybros_agent/realtime"
require_relative "../support/fake_realtime_client"
require_relative "../support/run_fixtures"

class ToolResultWaitTest < Minitest::Test
  include CybrosAgentTest::RunFixtures

  class LiveClient < CybrosAgentTest::FakeRealtimeClient
    attr_reader :live, :removed

    def subscribe(channel:, params: {}, timeout: nil)
      @subscriptions << Opened.new(channel, params)
      @live = CybrosAgent::Realtime::Subscription.new(client: self, identifier: channel, wire_identifier: channel)
    end

    def unsubscribe(subscription)
      @removed = subscription
      subscription.finish
    end

    def close = raise("a result wait must not close the shared client")
  end

  class RejectedClient < LiveClient
    def subscribe(**) = raise(CybrosAgent::Realtime::SubscriptionRejectedError)
  end

  class OccupiedClient < LiveClient
    def subscribe(**) = raise(ArgumentError, "already subscribed to the Run's events")
  end

  class RecoveringClient < LiveClient
    attr_reader :connections

    def initialize
      super
      @connections = 0
    end

    def connect_for_feed(welcome_timeout: nil)
      @connections += 1
      raise CybrosAgent::TransportError, "connection unavailable" if @connections == 1

      self
    end
  end

  class SlowClient < LiveClient
    attr_reader :connecting

    def connect_for_feed(welcome_timeout: nil)
      @connecting = true
      sleep 10
      self
    end
  end

  class BrokenClient < LiveClient
    def subscribe(**) = raise("unexpected client failure")
  end

  def wait(run, **options)
    Async { |scope| scope.with_timeout(1) { run.wait_for_tool_result(**options) } }.wait
  end

  def event(key = "call_tool", status: "completed", type: "task_status")
    { "public_id" => "event-1", "sequence" => 100, "cursor" => "cursor-100", "type" => type,
      "resource" => { "type" => "run", "public_id" => RUN_ID },
      "occurred_at" => "2026-10-13T00:00:00Z", "payload" => { "task_key" => key, "status" => status } }
  end

  def detail(status)
    [200, {}, { "task" => TASK.merge("key" => "call_tool", "status" => status, "output" => "authoritative") }]
  end

  def assert_task_reads(count)
    assert_equal ["#{RUN_PATH}/tasks/call_tool"] * count, @transport.requests.map { |request| request[:path] }
  end

  def test_subscription_confirmation_recovers_completion_without_replaying_events
    realtime = CybrosAgentTest::FakeRealtimeClient.new
    run = workspace([detail("dispatched"), detail("completed")]).runs.run(RUN_ID)
    result = wait(run, realtime: realtime, poll: 10)
    assert_equal "authoritative", result.output
    assert_task_reads 2
    assert_equal "events", realtime.subscriptions.fetch(0).params.fetch(:items)
  end

  def test_only_the_tools_terminal_event_wakes_the_authoritative_read
    realtime = LiveClient.new
    run = workspace([detail("dispatched"), detail("dispatched"), detail("completed")]).runs.run(RUN_ID)
    Async do |scope|
      waiting = scope.async { run.wait_for_tool_result(realtime: realtime, poll: 10) }
      scope.with_timeout(1) { scope.yield until @transport.requests.length >= 2 }
      assert_task_reads 2
      realtime.live.deliver({ "event" => event("elsewhere") })
      realtime.live.deliver({ "event" => event(status: "dispatched") })
      realtime.live.deliver({ "event" => event(type: "turn_status") })
      scope.yield
      assert_task_reads 2
      refute_predicate waiting, :finished?

      realtime.live.deliver({ "event" => event })
      result = scope.with_timeout(1) { waiting.wait }
      assert_equal "authoritative", result.output
      assert_task_reads 3
      assert_predicate realtime.live, :closed?
    end.wait
  end

  def test_a_silent_subscription_uses_the_rest_fallback
    realtime = LiveClient.new
    run = workspace([detail("dispatched"), detail("dispatched"), detail("completed")]).runs.run(RUN_ID)
    assert_equal "completed", wait(run, realtime: realtime, poll: 0.01).task.status
    assert_task_reads 3
    assert_predicate realtime.live, :closed?
  end

  def test_an_already_terminal_task_does_not_open_a_subscription
    realtime = CybrosAgentTest::FakeRealtimeClient.new
    result = wait(workspace([detail("completed")]).runs.run(RUN_ID), realtime: realtime)
    assert_equal "completed", result.task.status
    assert_empty realtime.subscriptions
    assert_task_reads 1
  end

  def test_rejection_keeps_the_authoritative_poll
    realtime = RejectedClient.new
    run = workspace([detail("dispatched"), detail("completed")]).runs.run(RUN_ID)
    assert_equal "completed", wait(run, realtime: realtime, poll: 0.01).task.status
    assert_task_reads 2
  end

  def test_an_existing_subscription_leaves_the_wait_on_rest_without_closing_it
    realtime = OccupiedClient.new
    run = workspace([detail("dispatched"), detail("completed")]).runs.run(RUN_ID)
    assert_equal "completed", wait(run, realtime: realtime, poll: 0.01).task.status
    assert_task_reads 2
  end

  def test_a_cleanly_closed_subscription_stays_on_rest
    realtime = CybrosAgentTest::FakeRealtimeClient.new
    run = workspace([detail("dispatched"), detail("dispatched"), detail("completed")]).runs.run(RUN_ID)
    assert_equal "completed", wait(run, realtime: realtime, poll: 0.01).task.status
    assert_equal 1, realtime.subscriptions.length
    assert_task_reads 3
  end

  def test_canceling_a_wait_removes_only_its_subscription
    realtime = LiveClient.new
    run = workspace([detail("dispatched"), detail("dispatched")]).runs.run(RUN_ID)
    Async do |scope|
      waiting = scope.async { run.wait_for_tool_result(realtime: realtime, poll: 10) }
      refute_nil realtime.live
      waiting.stop
      assert_same realtime.live, realtime.removed
      assert_predicate realtime.live, :closed?
      refute @transport.requests.any? { |request| request[:path].end_with?("/stop") }
      refute @transport.requests.any? { |request| request[:path].end_with?("/events") }
    end.wait
  end

  def test_patience_still_forces_stop_and_reads_the_terminal_task
    realtime = LiveClient.new
    run = workspace([detail("dispatched"), detail("dispatched"),
      [200, {}, { "run" => RUN.merge("status" => "canceling") }], detail("canceled")]).runs.run(RUN_ID)
    # Expire after subscription confirmation, independently of parsing and
    # instrumentation time; those must not change the scripted response order.
    run.define_singleton_method(:monotonic_now) { realtime.live ? 1.0 : 0.0 }
    result = wait(run, realtime: realtime, poll: 10, patience: 0.03)
    assert_equal "canceled", result.task.status
    assert_equal 1, @transport.requests.count { |request| request[:path].end_with?("/stop") }
    assert_equal :post, request(2)[:method]
    assert_equal "#{RUN_PATH}/stop", request(2)[:path]
    assert_equal({ "force" => true }, request(2)[:body])
    assert_equal "#{RUN_PATH}/tasks/call_tool", request(3)[:path]
    refute @transport.requests.any? { |request| request[:path].end_with?("/events") }
    assert_predicate realtime.live, :closed?
  end

  def test_disconnect_rereads_the_task_and_resubscribes_if_it_is_still_running
    realtime = LiveClient.new
    run = workspace([detail("dispatched"), detail("dispatched"), detail("dispatched"), detail("completed")]).runs.run(RUN_ID)
    Async do |scope|
      waiting = scope.async { run.wait_for_tool_result(realtime: realtime, poll: 10) }
      previous = realtime.live
      previous.finish(CybrosAgent::Realtime::ConnectionLostError.new(reason: "lost"))
      scope.with_timeout(1) { assert_equal "completed", waiting.wait.task.status }
      assert_equal 2, realtime.subscriptions.length
      assert_predicate previous, :closed?
      assert_predicate realtime.live, :closed?
      assert_task_reads 4
    end.wait
  end

  def test_a_failed_connection_retries_on_the_next_poll
    realtime = RecoveringClient.new
    run = workspace([detail("dispatched"), detail("dispatched"), detail("completed")]).runs.run(RUN_ID)
    assert_equal "completed", wait(run, realtime: realtime, poll: 0.01).task.status
    assert_equal 2, realtime.connections
    assert_task_reads 3
  end

  def test_connection_setup_does_not_block_the_rest_fallback
    realtime = SlowClient.new
    run = workspace([detail("dispatched"), detail("completed")]).runs.run(RUN_ID)
    assert_equal "completed", wait(run, realtime: realtime, poll: 0.01).task.status
    assert realtime.connecting
    assert_task_reads 2
  end

  def test_an_unexpected_client_failure_reaches_the_caller
    realtime = BrokenClient.new
    run = workspace([detail("dispatched")]).runs.run(RUN_ID)
    error = Async { assert_raises(RuntimeError) { run.wait_for_tool_result(realtime: realtime, poll: 10) } }.wait
    assert_equal "unexpected client failure", error.message
    assert_task_reads 1
  end
end
