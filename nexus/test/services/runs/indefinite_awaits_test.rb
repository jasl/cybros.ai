require "test_helper"
require_relative "../../test_helpers/awaits_test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class Runs::IndefiniteAwaitsTest < ActiveJob::TestCase
  include AwaitsTestHelper
  include RowLockTestHelper

  uses_transaction :test_concurrent_recovery_resolves_once_and_appends_one_successor

  test "an explicit coordination hold survives a month offline and resumes the same run without replaying its check" do
    with_clock do
      run = checked_run
      check = node(run, "check")
      hold = node(run, "hold")
      token = hold.resolution_token
      assert_nil hold.deadline_at
      assert_nil hold.wall_deadline_at
      assert_equal "dispatched", hold.status

      travel 31.days
      assert_equal 0, Runs::Parks::TimeoutSweep.call[:expired]
      assert_not_includes frontier_ids, hold.id
      assert_equal :idle, Runs::Parks::Settle.call(node: hold.reload, timeout: true).outcome
      Runs::EvaluateQuiescence.call(run.reload)
      assert_equal "running", run.reload.status
      assert_nil run.attention_reason
      assert_equal token, hold.reload.resolution_token
      assert_equal check.id, node(run, "check").id
      assert_equal "completed", check.reload.status
      assert_equal 0, check.execution_generation

      # Coordination survived, but an expired Runner credential is no new-work grant.
      assert_equal :runner_not_eligible, recover(run).outcome
      assert_equal "dispatched", hold.reload.status
      @suite_runner = @suite_runner_connection = nil
      suite_runner
      accepted = recover(run)
      assert_predicate accepted, :applied?, accepted.outcome.inspect
      replay = recover(run)
      assert_predicate replay, :replayed?, replay.outcome.inspect
      assert_equal accepted.receipt, replay.receipt
      assert_equal 1, run.tasks.where(node_key: "next").count
      assert_equal "completed", hold.reload.status
      assert_equal "checked once", check.output_body.effective_text
      Runs::ScheduleReady.call(run_id: run.id)
      assert_equal "dispatched", node(run, "next").status
      assert_equal "completed", node(run, "check").status
    end
  end

  test "finite awaits and claimed writes still expire beside an indefinite hold" do
    with_clock do
      run = seed(parallel(await("hold", "indefinite" => true),
        await("finite", "timeout_ms" => 7.days.in_milliseconds),
        tool("write", "bash", "timeout_ms" => 60_000)), model("after"))
      start!(run)
      claimed = Executors::Claim.call(Executors::Claim::Command.new(run: run, task_key: "write", executor: suite_runner))
      assert_predicate claimed, :accepted?
      travel 25.hours
      assert_equal 2, Runs::Parks::TimeoutSweep.call[:expired]
      assert_equal "dispatched", node(run, "hold").status
      assert_nil node(run, "hold").deadline_at
      assert_equal "timed_out", node(run, "finite").status
      assert_equal "uncertain", node(run, "write").status
      assert_equal 0, node(run, "write").execution_generation
    end
  end

  test "stop cancels an indefinite hold and late recovery cannot revive it" do
    run = checked_run
    assert_predicate Runs::Stop.call(Runs::Stop::Command.forced(run: run, acting_user: @human)), :accepted?
    Runs::ScheduleReady.call(run_id: run.id)
    assert_equal "canceled", node(run, "hold").status
    assert_not_predicate recover(run), :applied?
    assert_equal 0, run.tasks.where(node_key: "next").count
    assert_equal :idle, resolve!(node(run, "hold")).outcome
    assert_equal "completed", node(run, "check").status
  end

  test "graceful stop retains its drain ceiling even for an indefinite hold" do
    with_clock do
      run = checked_run
      stopped = Runs::Stop.call(Runs::Stop::Command.new(run: run, acting_user: @human, force: false))
      assert_predicate stopped, :accepted?
      assert_equal "canceling", run.reload.status
      assert_not_predicate recover(run), :applied?
      travel 25.hours
      assert_equal 0, Runs::Parks::TimeoutSweep.call[:expired]
      assert_equal 1, Runs::DrainSweep.call[:escalated]
      assert_equal "canceled", run.reload.status
      assert_equal "canceled", node(run, "hold").status
      assert_equal 0, run.tasks.where(node_key: "next").count
    end
  end

  test "abandoning a failed indefinite hold never rearms it" do
    run = checked_run
    assert_predicate resolve!(node(run, "hold"), outcome: "failed"), :applied?
    result = Runs::Tasks::Abandon.call(Runs::Tasks::Abandon::Command.new(run: run, task_key: "hold", acting_user: @human))
    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal "abandoned", node(run, "hold").failure_resolution
    assert_equal "failed", node(run, "hold").status
    Runs::ScheduleReady.call(run_id: run.id)
    assert_equal "needs_attention", run.reload.status
    assert_equal "failed", node(run, "hold").status
    assert_equal 0, run.tasks.where(node_key: "next").count
  end

  test "a resumed business tool still crosses its own approval stage" do
    run = checked_run(approval_rules: [{ "tool" => "bash", "origin" => "author", "verdict" => "ask" }])
    assert_predicate recover(run), :applied?
    Runs::ScheduleReady.call(run_id: run.id)
    successor = node(run, "next")
    assert_equal "needs_approval", successor.status
    assert_not_nil successor.deadline_at
    assert_nil successor.claimed_at
    assert_equal :not_addressed_here, Executors::Claim.call(Executors::Claim::Command.new(
      run: run, task_key: "next", executor: suite_runner
    )).outcome
  end

  test "concurrent recovery resolves once and appends one successor" do
    run = checked_run
    held = hold_row_lock(Run, run.id)
    calls = 2.times.map { start_database_call { recover(Run.find(run.id)) } }
    wait_until_waiting_on_lock(*calls.map(&:pid))
    release_row_lock(held)
    held = nil
    results = calls.map { |call| finish_database_call(call) }
    assert_equal 1, results.count(&:applied?)
    assert_equal 1, results.count(&:replayed?)
    assert_equal 1, run.tasks.where(node_key: "next").count
    assert_equal 1, node(run, "hold").content_bodies.where(role: "output").count
    assert_equal "completed", node(run, "check").status
    Runs::ScheduleReady.call(run_id: run.id)
    first = Executors::Claim.call(Executors::Claim::Command.new(run: run, task_key: "next", executor: suite_runner))
    second = Executors::Claim.call(Executors::Claim::Command.new(run: run, task_key: "next", executor: suite_runner))
    assert_predicate first, :accepted?
    assert_not_predicate second, :accepted?
  ensure
    release_row_lock(held) if held
    calls&.each { |call| call.thread.join(5) }
    Runs::Reap.destroy_aggregate(Run.find(run.id)) if run
  end

  private

    def with_clock(&block)
      travel_to Time.current.change(usec: 0)
      DatabaseClock.stub(:now, -> { Time.current }, &block)
    ensure
      travel_back
    end

    def checked_run(**options)
      run = seed(tool("check", "read_file", "timeout_ms" => 600_000),
        await("hold", "indefinite" => true), **options)
      start!(run)
      claim = Executors::Claim.call(Executors::Claim::Command.new(run: run, task_key: "check", executor: suite_runner))
      assert_predicate claim, :accepted?
      assert_predicate Runs::Parks::Settle.call(node: node(run, "check"), claim_token: claim.value.claim_token,
        content: "checked once", structured_content: { "exit_status" => 0 }), :applied?
      Runs::ScheduleReady.call(run_id: run.id)
      run.reload
    end

    def recover(run)
      grow(run, tool("next", "bash"),
        resolves: [{ "task" => "hold", "content" => "passed" }], idempotency_key: "advance-check")
    end
end
