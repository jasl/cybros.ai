require "test_helper"

class Runs::RaceBranchFailureTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @attempts = {}
    DevModelLane.ensure_enabled!(@account)
  end

  test "a failed ancestor cannot hold the loop after its losing branch was canceled" do
    run = seed(
      parallel(model("fast"), [model("slow-head"), model("slow-tail")], until: "any", key: "race"),
      model("after")
    )
    start_loop(run)

    finish_step(run, "slow-head", json_response(400, { "error" => "bad" }))
    assert_equal "failed", node(run, "slow-head").status
    assert_equal "queued", node(run, "slow-tail").status
    assert_equal "running", run.reload.status, "the other racer can still answer"

    finish_step(run, "fast", sse_success("the answer"))
    assert_equal "completed", node(run, "race").status
    tail = node(run, "slow-tail")
    assert_equal "canceled", tail.status
    assert_equal "join_loser_canceled", tail.error_key
    assert_equal "running", node(run, "after").status

    finish_step(run, "after", sse_success("done"))
    assert_equal "completed", run.reload.status,
      "a failed task whose only consumer was canceled by the race no longer holds an obligation"
    assert_nil run.attention_reason
    assert_nil node(run, "slow-head").failure_resolution,
      "the race absorbs the failure without rewriting the person's adjudication"
  end

  test "a quorum also absorbs an earlier failure in a canceled losing branch" do
    run = seed(
      parallel(model("fast-a"), model("fast-b"), [model("slow-head"), model("slow-tail")],
        until: 2, key: "race"),
      model("after")
    )
    start_loop(run)

    finish_step(run, "slow-head", json_response(400, { "error" => "bad" }))
    finish_step(run, "fast-a", sse_success("one answer"))
    assert_equal "queued", node(run, "race").status, "one success is still below the quorum"
    finish_step(run, "fast-b", sse_success("the other answer"))
    assert_equal "completed", node(run, "race").status
    assert_equal "join_loser_canceled", node(run, "slow-tail").error_key

    finish_step(run, "after", sse_success("done"))
    assert_equal "completed", run.reload.status
    assert_equal :resolved, Runs::Graph.settlement_of(node(run, "slow-head"))
    assert_nil node(run, "slow-head").failure_resolution
  end

  test "run_out still waits for a halted unfinished branch and retry lets it finish" do
    run = seed(
      parallel(model("fast"), [model("slow-head"), model("slow-tail")],
        until: "any", key: "race", losers: "run_out"),
      model("after")
    )
    start_loop(run)

    finish_step(run, "slow-head", json_response(400, { "error" => "bad" }))
    finish_step(run, "fast", sse_success("the answer"))
    finish_step(run, "after", sse_success("done"))
    assert_equal "completed", node(run, "race").status
    assert_equal "queued", node(run, "slow-tail").status
    assert_equal "needs_attention", run.reload.status
    assert_equal "halt_failure", run.attention_reason
    assert_equal :pending, Runs::Graph.settlement_of(node(run, "slow-head"))

    result = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: run, task_key: "slow-head", acting_user: @human
    ))
    assert_predicate result, :accepted?
    schedule(run)
    finish_step(run, "slow-head", sse_success("recovered"))
    assert_equal "running", node(run, "slow-tail").status
    finish_step(run, "slow-tail", sse_success("finished the branch"))
    assert_equal "completed", run.reload.status
  end

  test "a failure with a live plain consumer is not absorbed by its canceled race consumer" do
    run = seed(
      parallel(model("fast"), [model("slow-head"), model("slow-tail")], until: "any", key: "race"),
      model("after")
    )
    head = node(run, "slow-head")
    # A kernel splice can share a task with a second branch; no direct edge
    # writes may bypass the compiler's dependency and read validation here.
    result = Runs::Tasks::Append.call(Runs::Tasks::Append::Command.kernel(
      run: run, origin: "kernel",
      steps: [Runs::Tasks::Step::Model.new(key: "shared", model: MOCK_MODEL, prompt: "use the head")],
      tip: kernel_tip(head, [head], [], "branch")
    ))
    assert_predicate result, :applied?, result.outcome.inspect
    start_loop(run)

    finish_step(run, "slow-head", json_response(400, { "error" => "bad" }))
    finish_step(run, "fast", sse_success("the answer"))
    finish_step(run, "after", sse_success("done"))
    assert_equal "completed", node(run, "race").status
    assert_equal "join_loser_canceled", node(run, "slow-tail").error_key
    assert_equal "queued", node(run, "shared").status
    assert_equal "needs_attention", run.reload.status
    assert_equal "halt_failure", run.attention_reason
    assert_equal :pending, Runs::Graph.settlement_of(node(run, "slow-head"))
  end

  def start_loop(run)
    result = Runs::Start.call(Runs::Start::Command.new(
      run: run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    schedule(run)
  end

  def finish_step(run, key, behavior)
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @attempts[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    apply_via(@attempts.fetch(node(run, key).selected_model_invocation_id), behavior)
    Runs::ConvergeTerminalSteps.call
    schedule(run)
  end

  def schedule(run)
    Runs::ScheduleReady.call(run_id: run.id)
    clear_enqueued_jobs
  end

  def node(run, key) = run.tasks.find_by!(node_key: key)
end
