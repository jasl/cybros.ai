require "test_helper"

class AgentRuns::RaceBranchFailureTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @attempts = {}
    DevModelLane.ensure_enabled!(@account)
  end

  test "a failed ancestor cannot hold the loop after its losing branch was canceled" do
    agent_run = seed(
      parallel(model("fast"), [model("slow-head"), model("slow-tail")], until: "any", key: "race"),
      model("after")
    )
    start_loop(agent_run)

    finish_step(agent_run, "slow-head", json_response(400, { "error" => "bad" }))
    assert_equal "failed", node(agent_run, "slow-head").status
    assert_equal "queued", node(agent_run, "slow-tail").status
    assert_equal "running", agent_run.reload.status, "the other racer can still answer"

    finish_step(agent_run, "fast", sse_success("the answer"))
    assert_equal "completed", node(agent_run, "race").status
    tail = node(agent_run, "slow-tail")
    assert_equal "canceled", tail.status
    assert_equal "join_loser_canceled", tail.error_key
    assert_equal "running", node(agent_run, "after").status

    finish_step(agent_run, "after", sse_success("done"))
    assert_equal "completed", agent_run.reload.status,
      "a failed task whose only consumer was canceled by the race no longer holds an obligation"
    assert_nil agent_run.attention_reason
    assert_nil node(agent_run, "slow-head").failure_resolution,
      "the race absorbs the failure without rewriting the person's adjudication"
  end

  test "a quorum also absorbs an earlier failure in a canceled losing branch" do
    agent_run = seed(
      parallel(model("fast-a"), model("fast-b"), [model("slow-head"), model("slow-tail")],
        until: 2, key: "race"),
      model("after")
    )
    start_loop(agent_run)

    finish_step(agent_run, "slow-head", json_response(400, { "error" => "bad" }))
    finish_step(agent_run, "fast-a", sse_success("one answer"))
    assert_equal "queued", node(agent_run, "race").status, "one success is still below the quorum"
    finish_step(agent_run, "fast-b", sse_success("the other answer"))
    assert_equal "completed", node(agent_run, "race").status
    assert_equal "join_loser_canceled", node(agent_run, "slow-tail").error_key

    finish_step(agent_run, "after", sse_success("done"))
    assert_equal "completed", agent_run.reload.status
    assert_equal :resolved, AgentRuns::Graph.settlement_of(node(agent_run, "slow-head"))
    assert_nil node(agent_run, "slow-head").failure_resolution
  end

  test "run_out still waits for a halted unfinished branch and retry lets it finish" do
    agent_run = seed(
      parallel(model("fast"), [model("slow-head"), model("slow-tail")],
        until: "any", key: "race", losers: "run_out"),
      model("after")
    )
    start_loop(agent_run)

    finish_step(agent_run, "slow-head", json_response(400, { "error" => "bad" }))
    finish_step(agent_run, "fast", sse_success("the answer"))
    finish_step(agent_run, "after", sse_success("done"))
    assert_equal "completed", node(agent_run, "race").status
    assert_equal "queued", node(agent_run, "slow-tail").status
    assert_equal "needs_attention", agent_run.reload.status
    assert_equal "halt_failure", agent_run.attention_reason
    assert_equal :pending, AgentRuns::Graph.settlement_of(node(agent_run, "slow-head"))

    result = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "slow-head", acting_user: @human
    ))
    assert_predicate result, :accepted?
    schedule(agent_run)
    finish_step(agent_run, "slow-head", sse_success("recovered"))
    assert_equal "running", node(agent_run, "slow-tail").status
    finish_step(agent_run, "slow-tail", sse_success("finished the branch"))
    assert_equal "completed", agent_run.reload.status
  end

  test "a failure with a live plain consumer is not absorbed by its canceled race consumer" do
    agent_run = seed(
      parallel(model("fast"), [model("slow-head"), model("slow-tail")], until: "any", key: "race"),
      model("after")
    )
    head = node(agent_run, "slow-head")
    # A kernel splice can share a task with a second branch; no direct edge
    # writes may bypass the compiler's dependency and read validation here.
    result = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: agent_run, origin: "kernel",
      steps: [AgentRuns::Tasks::Step::Model.new(key: "shared", model: MOCK_MODEL, prompt: "use the head")],
      tip: kernel_tip(head, [head], [], "branch")
    ))
    assert_predicate result, :applied?, result.outcome.inspect
    start_loop(agent_run)

    finish_step(agent_run, "slow-head", json_response(400, { "error" => "bad" }))
    finish_step(agent_run, "fast", sse_success("the answer"))
    finish_step(agent_run, "after", sse_success("done"))
    assert_equal "completed", node(agent_run, "race").status
    assert_equal "join_loser_canceled", node(agent_run, "slow-tail").error_key
    assert_equal "queued", node(agent_run, "shared").status
    assert_equal "needs_attention", agent_run.reload.status
    assert_equal "halt_failure", agent_run.attention_reason
    assert_equal :pending, AgentRuns::Graph.settlement_of(node(agent_run, "slow-head"))
  end

  def start_loop(agent_run)
    result = AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    schedule(agent_run)
  end

  def finish_step(agent_run, key, behavior)
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @attempts[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    apply_via(@attempts.fetch(node(agent_run, key).selected_model_invocation_id), behavior)
    AgentRuns::ConvergeTerminalSteps.call
    schedule(agent_run)
  end

  def schedule(agent_run)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)
end
