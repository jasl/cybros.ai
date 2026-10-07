require "test_helper"

# EVERY KERNEL AUTHOR, PINNED BY WHAT ITS STEP READS. An authored step reads only what it names;
# the loop's own conversation is the one recorded difference, and only an author that hands a mainline
# continues one: ExpandRound after its fan, the wake and the plant, the lifecycle hook's
# continuation. Every branch the kernel roots is fresh, and a head the kernel hands waits alone
# (`splice_reads: false`) gains them and nothing to read.
class AgentRuns::ContinuationAuthorsTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  Step = AgentRuns::Tasks::Step
  Tip = AgentRuns::Tasks::Tip

  BULK = ("the quick brown fox files a report. " * 600).freeze
  TOOL = "my_compactor".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  # Stamped, not transitioned: only the settlements matter to a read.
  def stamp!(agent_run, key, status: "completed")
    AgentRunTask.where(id: node(agent_run, key).id).update_all(status: status, completed_at: Time.current)
  end

  def kernel!(agent_run, steps, tip, **command)
    result = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: agent_run, steps: steps, tip: tip, origin: "kernel", **command
    ))
    assert_predicate result, :applied?, "#{result.outcome}: #{result.errors.inspect}"
  end

  # A loop whose mainline round has answered, as the wake and the hooks find it.
  def settled_loop
    agent_run = seed(model("r1"))
    stamp!(agent_run, "r1")
    agent_run.update!(status: "running")
    agent_run
  end

  def reads(node) = [node.input_from_node_keys, node.result_from_node_keys]

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: agent_run.creating_user))
    schedule_loop!(agent_run)
  end

  test "ExpandRound's continuation continues the round and reads its paired calls" do
    agent_run = seed(model("round1", "tools" => [READ_TOOL]))
    start!(agent_run)
    run_loop_round!(agent_run, sse_success("calling", tool_calls: [
      { id: "call_a", name: "read_file", arguments: '{"path":"a"}' },
      { id: "call_b", name: "read_file", arguments: '{"path":"b"}' },
    ]))

    assert_equal [%w[round1 r1t0 r1t1], nil], reads(node(agent_run, "r1"))
    assert_equal "round", node(agent_run, "r1").continuation_source
  end

  # The wake continues the mainline's tail and reads every pending tip beside it: an ordinary tip as
  # material, a stage's value — behind a boundary the wake is not inside — as a result.
  test "the wake reads the mainline's tail and its tips; the plant reads its source alone" do
    agent_run = settled_loop
    kernel!(agent_run, [Step::Tool.new(key: "bg", name: "shell", detached: true),
                         Step::Tool.new(key: "s", name: "shell", detached: true)], Tip.seed("branch"))
    kernel!(agent_run, [Step::Tool.new(key: "leaf", name: "shell")],
      Tip.seed("branch").with(detached: true), expansion_parent: node(agent_run, "s"), child_work: true)
    request = { "kind" => "tool", "name" => "shell", "input" => {} }
    node(agent_run, "s").task_operations.create!(operation_key: "leaf", kind: "tool", request: request,
      request_digest: Nexus::CanonicalJson.digest(request), position: 1,
      response: { "receipt" => { "task_keys" => ["leaf"], "result_task_keys" => ["leaf"] } })
    %w[bg s leaf].each { |key| stamp!(agent_run, key) }

    assert_equal "w1", AgentRuns::WakeContinuation.call(agent_run: agent_run.reload)
    assert_equal [%w[r1 bg], %w[s]], reads(node(agent_run, "w1"))

    stamp!(agent_run, "w1")
    assert_equal "w2", AgentRuns::WakeContinuation.plant(agent_run: agent_run.reload, source: node(agent_run, "w1"))
    assert_equal [%w[w1], nil], reads(node(agent_run, "w2"))
  end

  test "a lifecycle hook's continuation continues its source and waits on the hook without reading it" do
    agent_run = settled_loop
    kernel!(agent_run, [Step::Tool.new(key: "h1", name: "shell")], Tip.seed("branch"))
    stamp!(agent_run, "h1")
    r1 = node(agent_run, "r1")
    AgentRuns::LifecycleHooks.append_continuation(agent_run, r1, r1, node(agent_run, "h1"), "keep going")

    continuation = node(agent_run, "w1")
    assert_equal [%w[r1], nil], reads(continuation)
    assert_equal %w[h1], continuation.sources.map(&:node_key)
  end

  # `KernelTool.branch_tip` roots task operations, `task`, `ask`, `wait`,
  # `spawn` and delegation in a fresh branch.
  test "every branch KernelTool.branch_tip roots is fresh" do
    agent_run = settled_loop
    kernel!(agent_run, [Step::Tool.new(key: "call", name: "shell")], Tip.seed("round"))
    call = node(agent_run, "call")
    kernel!(agent_run, [Step::Model.new(key: "waited", model: MOCK_MODEL, prompt: "p")],
      AgentRuns::KernelTool.branch_tip(call))
    kernel!(agent_run, [Step::Model.new(key: "background", model: MOCK_MODEL, prompt: "p")],
      AgentRuns::KernelTool.branch_tip(call).with(detached: true))

    %w[waited background].each do |key|
      assert_equal [nil, nil], reads(node(agent_run, key)), key
      assert_equal "branch", node(agent_run, key).continuation_source
      assert_equal %w[call], node(agent_run, key).sources.map(&:node_key), "it waits on its call"
    end
  end

  test "a waited task hands a named result and no positional material to its authored follower" do
    agent_run = settled_loop
    branch = AgentRuns::KernelTool.branch_tip(node(agent_run, "r1")).with(detached: true)
    kernel!(agent_run, [
      Step::Tool.new(key: "tc", name: "delegate_task", input: { "prompt" => "sub", "wait" => true }),
      Step::Model.new(key: "after-task", model: MOCK_MODEL, prompt: "p"),
      Step::Model.new(key: "named", model: MOCK_MODEL, prompt: "p", results: %w[tc]),
    ], branch)
    stamp!(agent_run, "tc", status: "running")
    AgentRuns::DelegateTaskTool::Run.call(node: node(agent_run, "tc"))

    assert_equal [nil, nil], reads(node(agent_run, "after-task"))
    assert_equal [nil, %w[tc-model-1]], reads(node(agent_run, "named"))
    assert_includes node(agent_run, "after-task").sources.map(&:node_key), "tc-model-1"
  end

  test "a lifecycle hook's tool hands its head a wait and nothing to read" do
    agent_run = settled_loop
    r1 = node(agent_run, "r1")
    kernel!(agent_run, [Step.inheriting(r1, key: "r2", prompt: "next")], kernel_tip(r1, [r1], [], "round"))
    head = node(agent_run, "r2")
    before = reads(head)

    hook = AgentRuns::LifecycleHooks.find_or_append(agent_run, "turn_start", head,
      policy: { "tool" => "shell", "timeout_ms" => 60_000 }, head: head)

    assert_equal before, reads(head.reload), "the head reads what it read before"
    assert_includes head.sources.map(&:node_key), hook.node_key, "and waits on the hook"
  end

  # THE ARM'S SUMMARIZER: a branch root the round waits on. It reads nothing by position — its
  # history is its own input — and the round finds the summary through its mark, never its reads.
  test "the arm's summarizer reads nothing by position, and its head gains a wait and nothing to read" do
    agent_run = seed(model("round1", "instructions" => "be useful", "prompt" => "start the work #{BULK}"),
      model("round2", "prompt" => "keep going #{BULK}"))
    start!(agent_run)
    run_loop_round!(agent_run, sse_success("here is what I found"))

    round2 = node(agent_run, "round2")
    assert_equal "k1", round2.compaction["summary_source"], "the wall armed the repair"
    assert_equal [%w[round1], nil], reads(round2), "the round reads what it read before"
    assert_includes round2.sources.map(&:node_key), "k1", "and waits on the summarizer"
    assert_equal [nil, nil], reads(node(agent_run, "k1"))

    run_loop_round!(agent_run, sse_success("THE SUMMARY"))
    assert_equal "k1", node(agent_run, "round2").arrived_summary.node_key
  end

  # THE FALLBACK'S SUMMARIZER: the kernel's replacement for a delegate nobody answered, placed the
  # way the arm places its own, under the same `splice_reads: false`.
  test "the fallback's summarizer head gains a wait and nothing to read" do
    address = TaskExecutor.address_for(@agent)
    declare_tools!(@agent, compaction_policy: { "mode" => "delegate", "tool_name" => TOOL })
    unless TaskExecutor.credential_readiness_for([address]).fetch(address.id) == :ready
      create_bound_credential(executor: address, name: "Lane transport")
    end
    assert_predicate address.announce(tools: [{ "name" => TOOL, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }]),
      :accepted?
    agent_run = seed(model("round1", "instructions" => "be useful", "prompt" => BULK),
      model("round2", "prompt" => BULK, "compaction" => { "mode" => "delegate", "tool_name" => TOOL }),
      creating_user: @agent)
    start!(agent_run)
    run_loop_round!(agent_run, sse_success("here is what I found"))
    claimed = Executors::Claim.call(Executors::Claim::Command.new(agent_run: agent_run, task_key: "k1", executor: address))
    assert_predicate claimed, :accepted?, claimed.outcome.inspect
    AgentRunTask.where(id: node(agent_run, "k1").id).update_all(await_started_at: 2.hours.ago)
    AgentRuns::Parks::TimeoutSweep.call

    round2 = node(agent_run, "round2")
    assert_equal "k2", round2.compaction["summary_source"], "the fallback replaced the expired delegate"
    assert_equal [%w[round1], nil], reads(round2)
    assert_includes round2.sources.map(&:node_key), "k2"
    assert_equal [nil, nil], reads(node(agent_run, "k2"))
  end
end
