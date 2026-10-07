require "test_helper"

# THE BRANCH-TIP FINDER: ONE descendant-closure walk over a branch's edges — `CancelBranch`'s,
# extracted — that names a branch's members from the call key the model saw or any branch node,
# never crossing a round-marked node or a barrier; and from it the branch's TIP (the round with no
# round below it in the branch) and the `task` calls whose settled, unmailed tip a later reader
# renders as the call's paired result.
class AgentRuns::BranchClosureTest < ActiveJob::TestCase
  include InvocationHarness

  READ_FILE = { "type" => "function",
                "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def model(key, **over)
    super(key, "tools" => [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::ASK, READ_FILE], **over)
  end

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  def schedule!(agent_run) = AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def step_attempt(agent_run, key)
    invocation_id = node(agent_run, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def loop_with_round
    agent_run = seed(model("round1", "prompt" => "do the work"))
    start!(agent_run)
    agent_run
  end

  # The running round answers with a fan of flat-tool calls, each
  # `[name, arguments]`; the kernel's jobs run.
  def fan!(agent_run, key, *calls)
    tool_calls = calls.each_with_index.map do |(name, fields), index|
      { id: "call_#{key}_#{index}", name: name, arguments: fields.to_json }
    end
    apply_via(step_attempt(agent_run, key), sse_success("calling", tool_calls: tool_calls))
    AgentRuns::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::AskJob, AgentRuns::ScheduleJob]) do
      schedule!(agent_run)
    end
    agent_run.reload
  end

  def run!(agent_run, key, text)
    apply_via(step_attempt(agent_run, key), sse_success(text))
    AgentRuns::ConvergeTerminalSteps.call
    schedule!(agent_run)
  end

  # A parked tool result lands, and the scheduler moves its consumer.
  def settle_tool!(agent_run, key, content)
    settled = AgentRuns::Parks::Settle.call(node: node(agent_run, key), trusted: true,
      content: content, outcome: "completed")
    assert_predicate settled, :applied?, key
    schedule!(agent_run)
  end

  def members(agent_run, key) = AgentRuns::BranchClosure.members(node(agent_run, key)).map(&:node_key).sort

  def tip_of(agent_run, key) = AgentRuns::BranchClosure.tip_of(node(agent_run, key))&.node_key

  def tips(agent_run, *keys)
    AgentRuns::BranchClosure.tips_by_call_key(keys.map { |key| node(agent_run, key) })
      .transform_values(&:node_key)
  end

  test "members: the call key and any branch node name the branch; the mainline and its fan name nothing" do
    agent_run = loop_with_round
    fan!(agent_run, "round1", ["delegate_task", { prompt: "dig in", wait: true }], ["read_file", { path: "a" }])
    fan!(agent_run, "r1t0-model-1", ["read_file", { path: "b" }])
    assert_equal %w[dispatched queued queued], %w[r2t0 r2 r1].map { |key| node(agent_run, key).status }

    assert_equal %w[r1t0-model-1 r2 r2t0], members(agent_run, "r1t0"), "the call the model saw"
    assert_equal %w[r1t0-model-1 r2 r2t0], members(agent_run, "r1t0-model-1"), "the branch root"
    assert_equal %w[r2 r2t0], members(agent_run, "r2t0"), "a call a branch round emitted, and what follows it"
    assert_equal %w[r2], members(agent_run, "r2"), "the branch's own continuation"
    assert_empty members(agent_run, "round1"), "a round-marked key is the mainline's"
    assert_empty members(agent_run, "r1"), "the mainline consumer is never branch work"
    assert_empty members(agent_run, "r1t1"), "a mainline fan member that started no branch"
  end

  test "members: a barrier is never crossed, and is itself no branch" do
    agent_run = loop_with_round
    fan!(agent_run, "round1", ["delegate_task", { prompt: "dig in", wait: true }])
    root = node(agent_run, "r1t0-model-1")
    race = AgentRuns::Tasks::Step::Parallel.new(
      members: [AgentRuns::Tasks::Step::Tool.new(name: "read_file", key: "a"),
                AgentRuns::Tasks::Step::Tool.new(name: "read_file", key: "b")],
      until: "any", key: "race"
    )
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: agent_run, origin: "model",
      steps: [race, AgentRuns::Tasks::Step::Model.new(prompt: "after", key: "after", model: MOCK_MODEL)],
      tip: kernel_tip(nil, [root], [], AgentRuns::Tasks::Compile::BRANCH)
    ))
    assert_predicate appended, :applied?, appended.outcome.inspect
    assert_equal "any", node(agent_run, "race").join_mode
    assert_equal %w[a b], node(agent_run, "race").sources.map(&:node_key)

    assert_equal %w[a b r1t0-model-1], members(agent_run, "r1t0"),
      "the fan a branch round waits on is the branch's; the barrier and what follows it are not"
    assert_empty members(agent_run, "race")
    assert_equal "r1t0-model-1", tip_of(agent_run, "r1t0"), "the barrier is no branch round"
  end

  test "tip_of: the branch's last round, as the branch grows" do
    agent_run = loop_with_round
    fan!(agent_run, "round1", ["delegate_task", { prompt: "dig in", wait: true }])
    assert_equal "r1t0-model-1", tip_of(agent_run, "r1t0"), "a fresh branch is its root"

    fan!(agent_run, "r1t0-model-1", ["read_file", { path: "a" }])
    assert_equal "r2", tip_of(agent_run, "r1t0"), "the root's continuation is the tip once it exists"

    settle_tool!(agent_run, "r2t0", "contents of a")
    fan!(agent_run, "r2", ["read_file", { path: "b" }])
    assert_equal "r3", tip_of(agent_run, "r1t0")
    assert_equal "r3", tip_of(agent_run, "r2"), "from any member, the same tip"
    assert_equal %w[r1t0-model-1 r2 r2t0 r3 r3t0], members(agent_run, "r1t0")

    settle_tool!(agent_run, "r3t0", "contents of b")
    run!(agent_run, "r3", "done: found it")
    tip = AgentRuns::BranchClosure.tip_of(node(agent_run, "r1t0"))
    assert_equal %w[r3 completed], [tip.node_key, tip.status]
    assert_nil tip_of(agent_run, "round1"), "the mainline has no tip"
    assert_nil tip_of(agent_run, "r1"), "nor its consumer"
  end

  test "nested waited delegation keeps its own members and final tip after its parent continues" do
    agent_run = loop_with_round
    fan!(agent_run, "round1", ["delegate_task", { prompt: "implement", wait: true }])
    fan!(agent_run, "r1t0-model-1", ["delegate_task", { prompt: "verify", wait: true }])
    fan!(agent_run, "r2t0-model-1", ["read_file", { path: "verification" }])

    expected = %w[r2t0-model-1 r3 r3t0]
    assert_equal ["r2t0", *expected], members(agent_run, "r2t0")
    assert_equal expected, members(agent_run, "r2t0-model-1")
    assert_equal %w[r3 r3t0], members(agent_run, "r3t0")
    assert_equal "r3", tip_of(agent_run, "r2t0")
    assert_equal "r2", tip_of(agent_run, "r1t0")

    settle_tool!(agent_run, "r3t0", "verification evidence")
    run!(agent_run, "r3", "verification complete")
    fan!(agent_run, "r2", ["read_file", { path: "implementation" }])

    assert_equal "r3", tip_of(agent_run, "r2t0"), "the parent continuation is outside the nested task"
    assert_equal "r4", tip_of(agent_run, "r1t0")
    assert_equal({ [agent_run.id, "r2t0"] => "r3" }, tips(agent_run, "r2t0"),
      "history pairs the nested call with its own final result")
    assert_equal expected, members(agent_run, "r2t0-model-1")
  end

  test "tips_by_call_key: task calls only, whose tip is terminal and unmailed" do
    agent_run = loop_with_round
    fan!(agent_run, "round1", ["delegate_task", { prompt: "one", wait: true }], ["delegate_task", { prompt: "two", wait: true }],
      ["ask", { prompt: "which database?" }])
    ask = node(agent_run, "r1t2-ask-1")
    assert_equal "awaiting_input", ask.status
    assert_predicate AgentRuns::Parks::Settle.call(node: ask, content: "Postgres"), :applied?
    assert_equal "completed", ask.reload.status

    calls = %w[r1t0 r1t1 r1t2]
    assert_equal({}, tips(agent_run, *calls), "a running tip is no result yet; an answered ask is read, not paired")

    run!(agent_run, "r1t1-model-1", "two done")
    assert_equal({ [agent_run.id, "r1t1"] => "r1t1-model-1" }, tips(agent_run, *calls), "keyed by the loop and call")

    AgentRunTask.where(id: node(agent_run, "r1t1-model-1").id).update_all(result_delivered_at: Time.current)
    assert_equal({}, tips(agent_run, *calls), "a mailed tip's delivery is the mail")

    run!(agent_run, "r1t0-model-1", "one done")
    assert_equal({ [agent_run.id, "r1t0"] => "r1t0-model-1" }, tips(agent_run, *calls))
    assert_equal({}, tips(agent_run, "r1t2"), "an ask call never pairs")
  end
end
