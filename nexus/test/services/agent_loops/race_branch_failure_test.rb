require "test_helper"

class AgentLoops::RaceBranchFailureTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @attempts = {}
    DevModelLane.ensure_enabled!(@account)
  end

  test "a failed ancestor cannot hold the loop after its losing branch was canceled" do
    agent_loop = seed(
      parallel(model("fast"), [model("slow-head"), model("slow-tail")], until: "any", key: "race"),
      model("after")
    )
    start_loop(agent_loop)

    finish_step(agent_loop, "slow-head", json_response(400, { "error" => "bad" }))
    assert_equal "failed", node(agent_loop, "slow-head").status
    assert_equal "queued", node(agent_loop, "slow-tail").status
    assert_equal "running", agent_loop.reload.status, "the other racer can still answer"

    finish_step(agent_loop, "fast", sse_success("the answer"))
    assert_equal "completed", node(agent_loop, "race").status
    tail = node(agent_loop, "slow-tail")
    assert_equal "canceled", tail.status
    assert_equal "join_loser_canceled", tail.error_key
    assert_equal "running", node(agent_loop, "after").status

    finish_step(agent_loop, "after", sse_success("done"))
    assert_equal "completed", agent_loop.reload.status,
      "a failed task whose only consumer was canceled by the race no longer holds an obligation"
    assert_nil agent_loop.attention_reason
    assert_nil node(agent_loop, "slow-head").failure_resolution,
      "the race absorbs the failure without rewriting the person's adjudication"
  end

  test "a quorum also absorbs an earlier failure in a canceled losing branch" do
    agent_loop = seed(
      parallel(model("fast-a"), model("fast-b"), [model("slow-head"), model("slow-tail")],
        until: 2, key: "race"),
      model("after")
    )
    start_loop(agent_loop)

    finish_step(agent_loop, "slow-head", json_response(400, { "error" => "bad" }))
    finish_step(agent_loop, "fast-a", sse_success("one answer"))
    assert_equal "queued", node(agent_loop, "race").status, "one success is still below the quorum"
    finish_step(agent_loop, "fast-b", sse_success("the other answer"))
    assert_equal "completed", node(agent_loop, "race").status
    assert_equal "join_loser_canceled", node(agent_loop, "slow-tail").error_key

    finish_step(agent_loop, "after", sse_success("done"))
    assert_equal "completed", agent_loop.reload.status
    assert_equal :resolved, AgentLoops::Graph.settlement_of(node(agent_loop, "slow-head"))
    assert_nil node(agent_loop, "slow-head").failure_resolution
  end

  test "run_out still waits for a halted unfinished branch and retry lets it finish" do
    agent_loop = seed(
      parallel(model("fast"), [model("slow-head"), model("slow-tail")],
        until: "any", key: "race", losers: "run_out"),
      model("after")
    )
    start_loop(agent_loop)

    finish_step(agent_loop, "slow-head", json_response(400, { "error" => "bad" }))
    finish_step(agent_loop, "fast", sse_success("the answer"))
    finish_step(agent_loop, "after", sse_success("done"))
    assert_equal "completed", node(agent_loop, "race").status
    assert_equal "queued", node(agent_loop, "slow-tail").status
    assert_equal "needs_attention", agent_loop.reload.status
    assert_equal "halt_failure", agent_loop.attention_reason
    assert_equal :pending, AgentLoops::Graph.settlement_of(node(agent_loop, "slow-head"))

    result = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: "slow-head", acting_user: @human
    ))
    assert_predicate result, :accepted?
    schedule(agent_loop)
    finish_step(agent_loop, "slow-head", sse_success("recovered"))
    assert_equal "running", node(agent_loop, "slow-tail").status
    finish_step(agent_loop, "slow-tail", sse_success("finished the branch"))
    assert_equal "completed", agent_loop.reload.status
  end

  test "a failure with a live plain consumer is not absorbed by its canceled race consumer" do
    agent_loop = seed(
      parallel(model("fast"), [model("slow-head"), model("slow-tail")], until: "any", key: "race"),
      model("after")
    )
    head = node(agent_loop, "slow-head")
    # A kernel splice can share a task with a second branch; no direct edge
    # writes may bypass the compiler's dependency and read validation here.
    result = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
      agent_loop: agent_loop, origin: "kernel",
      steps: [AgentLoops::Tasks::Step::Model.new(key: "shared", model: MOCK_MODEL, prompt: "use the head")],
      tip: kernel_tip(head, [head], [], "branch")
    ))
    assert_predicate result, :applied?, result.outcome.inspect
    start_loop(agent_loop)

    finish_step(agent_loop, "slow-head", json_response(400, { "error" => "bad" }))
    finish_step(agent_loop, "fast", sse_success("the answer"))
    finish_step(agent_loop, "after", sse_success("done"))
    assert_equal "completed", node(agent_loop, "race").status
    assert_equal "join_loser_canceled", node(agent_loop, "slow-tail").error_key
    assert_equal "queued", node(agent_loop, "shared").status
    assert_equal "needs_attention", agent_loop.reload.status
    assert_equal "halt_failure", agent_loop.attention_reason
    assert_equal :pending, AgentLoops::Graph.settlement_of(node(agent_loop, "slow-head"))
  end

  def start_loop(agent_loop)
    result = AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    assert_predicate result, :accepted?
    schedule(agent_loop)
  end

  def finish_step(agent_loop, key, behavior)
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @attempts[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    apply_via(@attempts.fetch(node(agent_loop, key).selected_model_invocation_id), behavior)
    AgentLoops::ConvergeTerminalSteps.call
    schedule(agent_loop)
  end

  def schedule(agent_loop)
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)
end
