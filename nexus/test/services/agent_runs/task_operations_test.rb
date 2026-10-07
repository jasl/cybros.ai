require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"
require_relative "../../test_helpers/lock_order_test_helper"

class AgentRuns::TaskOperationsTest < ActiveJob::TestCase
  include RowLockTestHelper
  include LockOrderTestHelper

  uses_transaction :test_expiry_fences_a_final_already_waiting_for_the_run_lock

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @runner = suite_runner
    DevModelLane.ensure_enabled!
    announce_program
  end

  test "a waiting parent retains its claim and renews without changing the child's clock" do
    with_clock do
      parent = start_program
      child = add_child(parent)
      token = parent.claim_token
      child_deadline = child.deadline_at
      assert_equal 90_000, parent.effective_timeout_ms
      travel 40.seconds

      assert_nil observe(parent).fetch("observation")
      assert_ladder_order("extend an operation owner") do
        assert_predicate extend(parent, timeout_ms: 90_000), :accepted?
      end
      assert_in_delta 90.seconds.from_now.to_f, parent.reload.deadline_at.to_f, 0.01
      assert_equal token, parent.claim_token
      assert_equal 0, parent.execution_generation
      assert_equal child_deadline, child.reload.deadline_at
      assert_predicate settle(child), :applied?

      assert_equal "done", observe(parent).dig("observation", "outcome", "output")
      assert_ladder_order("finalize an operation owner") { assert_predicate commit(parent), :applied? }
      assert_equal "completed", parent.reload.status
    end
  end

  test "a denied child is observed under the original live claim" do
    parent = start_program(approval_rules: [{ "tool" => "read_file", "origin" => "author",
      "verdict" => "deny", "reason" => "declared refusal" }])
    child = queue_child(parent)
    AgentRuns::ScheduleReady.call(agent_run_id: parent.agent_run_id)

    assert_equal %w[failed approval_denied], child.reload.values_at(:status, :error_key)
    assert_nil child.claimed_at
    result = observe(parent).fetch("observation")
    assert_equal "approval_denied", result.dig("outcome", "error", "key")
    assert_equal "dispatched", parent.reload.status
    assert_equal 0, parent.execution_generation
    assert_predicate commit(parent), :applied?
  end

  test "an unserved child is observed without replaying its parent" do
    parent = start_program
    child = queue_child(parent)
    assert_predicate @runner.announce(tools: @runner.served_tools.select { |entry| entry.fetch("name") == "program" }), :accepted?
    AgentRuns::ScheduleReady.call(agent_run_id: parent.agent_run_id)

    assert_equal %w[failed tool_not_served], child.reload.values_at(:status, :error_key)
    assert_equal "tool_not_served", observe(parent).dig("observation", "outcome", "error", "key")
    assert_equal "dispatched", parent.reload.status
    assert_equal 0, parent.execution_generation
  end

  test "owner loss times out replayable work without a new claim and cancels attached work" do
    with_clock do
      parent = start_program(timeout_ms: 60_000)
      child = add_child(parent)
      token = parent.claim_token
      travel 61.seconds

      AgentRuns::Parks::TimeoutSweep.call

      assert_equal %w[timed_out tool_timeout], parent.reload.values_at(:status, :error_key)
      assert_equal "canceled", child.reload.status
      assert_equal token, parent.claim_token
      assert_equal 0, parent.execution_generation
      assert_equal :task_not_claimable, claim(parent).outcome
      assert_equal :task_not_running, commit(parent).outcome
      assert_nil parent.output_body
    end
  end

  test "owner loss preserves uncertainty for a possibly escaped effect" do
    announce_program(profile: RunAuthoringTestHelper::WRITE_PROFILE)
    with_clock do
      parent = start_program(timeout_ms: 60_000)
      child = add_child(parent)
      travel 61.seconds

      AgentRuns::Parks::TimeoutSweep.call

      assert_equal %w[uncertain tool_uncertain], parent.reload.values_at(:status, :error_key)
      assert_equal "canceled", child.reload.status
      assert_equal 0, parent.execution_generation
      assert_equal :task_not_claimable, claim(parent).outcome
    end
  end

  test "a final at the database cutoff settles expiry instead of its pending children refusal" do
    parent = start_program
    child = add_child(parent)
    cutoff = parent.deadline_at
    travel_to cutoff do
      DatabaseClock.stub(:now, cutoff) do
        assert_predicate commit(parent), :applied?
      end
    end

    assert_equal "timed_out", parent.reload.status
    assert_equal "canceled", child.reload.status
    assert_nil parent.output_body
    assert_equal 0, parent.execution_generation
  end

  test "a result before the database cutoff wins despite a later application clock" do
    parent = start_program
    cutoff = parent.deadline_at
    travel_to cutoff + 1.second do
      DatabaseClock.stub(:now, cutoff - 1.second) { assert_predicate settle(parent), :applied? }
    end

    assert_equal "completed", parent.reload.status
    assert_equal "done", parent.output_body.effective_text
    assert_equal 0, parent.execution_generation
  end

  test "operations refuse at the database cutoff before application time reaches it" do
    parent = start_program
    DatabaseClock.stub(:now, parent.deadline_at) do
      result = access(parent).mutate { flunk "an expired claim accepted new work" }
      assert_equal :claim_expired, result.outcome
    end
    assert_empty parent.task_operations
    assert_equal 0, parent.execution_generation
  end

  test "pause freezes the existing claim while its child may settle" do
    with_clock do
      parent = start_program
      child = add_child(parent)
      token = parent.claim_token
      travel 4.seconds
      assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
        agent_run: parent.agent_run, acting_user: @human
      )), :accepted?
      assert_nil observe(parent).fetch("observation"), "waiting preserves the original claim during pause"
      assert_predicate settle(child), :applied?
      assert_equal "done", observe(parent).dig("observation", "outcome", "output")
      travel 1.hour
      AgentRuns::Parks::TimeoutSweep.call
      assert_equal "dispatched", parent.reload.status
      assert_equal :execution_paused, access(parent).mutate { flunk "paused operations" }.outcome

      assert_predicate AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
        agent_run: parent.agent_run, acting_user: @human
      )), :accepted?
      assert_equal token, parent.reload.claim_token
      assert_in_delta 86.seconds.from_now.to_f, parent.deadline_at.to_f, 0.01
      assert_nil observe(parent).fetch("observation"), "the paused observation remains sealed after resume"
      assert_predicate commit(parent), :applied?
    end
  end

  test "graceful Stop drains an accepted child through its original waiting claim" do
    parent = start_program
    child = add_child(parent)
    token = parent.claim_token
    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: parent.agent_run, acting_user: @human, force: false
    )), :accepted?
    assert_equal "canceling", parent.agent_run.reload.status
    assert_nil observe(parent).fetch("observation")
    assert_equal :execution_stopped, access(parent).mutate { flunk "new work during graceful Stop" }.outcome
    assert_predicate settle(child), :applied?
    assert_equal "done", observe(parent).dig("observation", "outcome", "output")
    assert_equal token, parent.reload.claim_token
    assert_predicate commit(parent), :applied?
  end

  test "forced Stop cuts the original parent and its live children" do
    parent = start_program
    child = add_child(parent)
    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: parent.agent_run, acting_user: @human
    )), :accepted?
    AgentRuns::ScheduleReady.call(agent_run_id: parent.agent_run_id)

    assert_equal %w[canceled canceled], [parent.reload.status, child.reload.status]
    assert_equal :task_not_claimable, claim(parent).outcome
    assert_equal :execution_stopped, access(parent).mutate { flunk "stopped operations" }.outcome
  end

  test "the sweep SQL and the renewed claim derive the same deadline" do
    with_clock do
      parent = start_program(timeout_ms: 40_000)
      travel 31.seconds
      assert_predicate extend(parent, timeout_ms: 60_000), :accepted?
      parent.reload
      sweep = AgentRuns::Parks::TimeoutSweep.new

      assert_not_includes sweep.send(:frontier, parent.deadline_at - 1.second).map(&:id), parent.id
      assert_includes sweep.send(:frontier, parent.deadline_at).map(&:id), parent.id
    end
  end

  test "expiry fences a final already waiting for the run lock" do
    parent = start_program
    queue_child(parent)
    parent.update_columns(await_started_at: 91.seconds.ago)
    held = hold_row_lock(AgentRun, parent.agent_run_id, before_commit: ->(locked) {
      current = locked.agent_run_tasks.find(parent.id)
      assert_predicate AgentRuns::Parks::Settle.call(node: current, timeout: true), :applied?
    })
    late = start_database_call { commit(parent) }
    wait_until_waiting_on_lock(late.pid)
    release_row_lock(held)
    held = nil

    assert_equal :task_not_running, finish_database_call(late).outcome
    assert_equal "timed_out", parent.reload.status
    assert_equal 0, parent.execution_generation
    assert_nil parent.output_body
  ensure
    release_row_lock(held) if held
    late&.thread&.join(5)
    AgentRuns::Reap.destroy_aggregate(AgentRun.find(parent.agent_run_id)) if parent
  end

  private

    def with_clock(&block)
      travel_to Time.current.change(usec: 0)
      DatabaseClock.stub(:now, -> { Time.current }, &block)
    ensure
      travel_back
    end

    def announce_program(profile: Nexus::ToolRegistry::READ_ONLY_CLOSED)
      assert_predicate @runner.announce(tools: RunAuthoringTestHelper::TEST_SERVED_TOOLS + [{
        "name" => "program", "effect_profile" => profile,
      }]), :accepted?
    end

    def start_program(timeout_ms: 90_000, approval_rules: nil)
      agent_run = seed(tool("program", "program", "route" => { "kind" => "runner" }, "timeout_ms" => timeout_ms,
        "model_defaults" => { "model" => { "model" => "dev/mock-text" },
          "tools" => fixture_runner_declarations([RunLaneTestHelper::READ_TOOL]) }), approval_rules: approval_rules)
      assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @human
      )), :accepted?
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      result = claim(agent_run.agent_run_tasks.sole)
      assert_predicate result, :accepted?, result.outcome.inspect
      result.value
    end

    def claim(node)
      Executors::Claim.call(Executors::Claim::Command.new(
        agent_run: node.agent_run, task_key: node.node_key, executor: @runner
      ))
    end

    def access(node)
      Executors::TaskOperations::Access.new(agent_run: node.agent_run, task_key: node.node_key,
        executor: @runner, claim_token: node.claim_token)
    end

    def queue_child(parent)
      result = Executors::TaskOperations::Submit.new(access: access(parent), key: "child",
        request: { "kind" => "tool", "name" => "read_file", "input" => {} }).call
      assert_predicate result, :accepted?, result.outcome.inspect
      assert_nil result.value.dig("operation", "refusal")
      parent.agent_run.agent_run_tasks.find_by!(node_key: result.value.dig("operation", "receipt", "task_keys").sole)
    end

    def add_child(parent)
      child = queue_child(parent)
      AgentRuns::ScheduleReady.call(agent_run_id: parent.agent_run_id)
      result = claim(child)
      assert_predicate result, :accepted?
      result.value
    end

    def observe(parent)
      result = Executors::TaskOperations::Observe.new(access: access(parent),
        after: Executors::TaskOperations::Trace.position(parent)).call
      assert_predicate result, :accepted?, result.outcome.inspect
      result.value
    end

    def extend(node, timeout_ms:)
      Executors::Extend.call(Executors::Extend::Command.new(agent_run: node.agent_run,
        task_key: node.node_key, executor: @runner, claim_token: node.claim_token, timeout_ms: timeout_ms))
    end

    def settle(node)
      AgentRuns::Parks::Settle.call(node: node, claim_token: node.claim_token, content: "done")
    end

    def commit(node)
      Executors::Commit.call(Executors::Commit::Command.new(agent_run: node.agent_run,
        task_key: node.node_key, executor: @runner, claim_token: node.claim_token,
        content: "done", structured_content: nil, result_type: nil, outcome: "completed",
        is_error: false, title: nil, metadata: nil))
    end
end
