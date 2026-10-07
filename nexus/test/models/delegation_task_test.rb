require "test_helper"

class DelegationTaskTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
    @agent_run = seed(ask("question"))
    @node = @agent_run.agent_run_tasks.create!(type: AgentRunTasks::DelegationTask.sti_name,
      node_key: "r2t0-delegation-1", lifetime: "turn", detached: true,
      authored_by: "kernel", on_failure: "absorb", retry_budget: 0)
  end

  test "a delegation runs without an inbox entry or deadline and force stop cancels it" do
    assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: @agent_run, acting_user: @human
    )), :accepted?
    AgentRuns::ScheduleReady.call(agent_run_id: @agent_run.id)

    assert_equal "running", @node.reload.status
    assert_not_predicate @node, :clocked?
    assert_nil @node.inbox_kind
    assert_nil @node.resolution_token
    assert_nil @node.await_started_at
    assert_nil @node.addressed_executor_id

    assert_predicate AgentRuns::Stop.stop_now(@agent_run.reload), :accepted?
    AgentRuns::ScheduleReady.call(agent_run_id: @agent_run.id)
    assert_equal "canceled", @node.reload.status
    assert_equal "canceled", @agent_run.reload.status
  end

  test "publication records an existing input identity once without a new execution generation" do
    input_id = SecureRandom.uuid
    @node.update!(delegated_input_public_id: input_id)
    @node.update!(delegated_input_public_id: input_id)
    assert_equal input_id, @node.reload.delegated_input_public_id
    assert_equal 0, @node.execution_generation

    [nil, SecureRandom.uuid].each do |replacement|
      @node.delegated_input_public_id = replacement
      assert_not_predicate @node, :valid?
      assert @node.errors.of_kind?(:delegated_input_public_id, :readonly)
      @node.reload
    end
  end

  test "lifetime is immutable and only the kernel can author an absorbing completion obligation" do
    assert_raises(ActiveRecord::ReadonlyAttributeError) { @node.lifetime = "conversation" }
    invalid = @node.dup
    invalid.node_key = "bad-delegation"
    invalid.lifetime = "conversation"
    invalid.authored_by = "author"
    invalid.on_failure = "halt"
    invalid.retry_budget = 1
    invalid.addressed_role = "tool_provider"
    invalid.timeout_ms = 5_000

    assert_not_predicate invalid, :valid?
    %i[lifetime authored_by on_failure retry_budget addressed_role timeout_ms].each do |field|
      assert invalid.errors[field].any?, "#{field} must not change the completion observation into executable work"
    end
  end

  test "task graph and event projections expose the same lifetime without the publication field" do
    task = AgentAPI::AgentRunPresenter.task(@node, live_server_ids: [])
    graph = AgentAPI::AgentRunGraphPresenter.call(@agent_run).nodes.find { |node| node.key == @node.node_key }
    AgentRuns::Transition.created(@agent_run, [@node])
    AgentRun::Narration.flush
    event = @agent_run.conversation_event_items.where(item_type: "task_status").order(:id).last.payload

    assert_equal ["turn", "turn", "turn"], [task[:lifetime], graph.lifetime, event.fetch("lifetime")]
    assert_equal ["delegation_task"] * 3, [task[:kind], graph.kind, event.fetch("kind")]
    assert_not task.key?(:delegated_input_public_id)
    assert_not graph.to_h.key?(:delegated_input_public_id)
    assert_not event.key?("delegated_input_public_id")
  end
end
