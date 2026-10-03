require "test_helper"

# EVERY KERNEL AUTHOR, PINNED BY WHAT ITS STEP READS. An authored step reads only what it names;
# the loop's own conversation is the one recorded difference, and only an author that hands a spine
# continues one: ExpandRound after its fan, the wake and the plant, the lifecycle hook's
# continuation. Every branch the kernel roots is fresh, and a head the kernel hands waits alone
# (`splice_reads: false`) gains them and nothing to read.
class AgentLoops::ContinuationAuthorsTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  Step = AgentLoops::Tasks::Step
  Tip = AgentLoops::Tasks::Tip

  BULK = ("the quick brown fox files a report. " * 600).freeze
  TOOL = "my_compactor".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  # Stamped, not transitioned: only the settlements matter to a read.
  def stamp!(agent_loop, key, status: "completed")
    AgentLoopNode.where(id: node(agent_loop, key).id).update_all(status: status, completed_at: Time.current)
  end

  def kernel!(agent_loop, steps, tip, **command)
    result = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
      agent_loop: agent_loop, steps: steps, tip: tip, origin: "kernel", **command
    ))
    assert_predicate result, :applied?, "#{result.outcome}: #{result.errors.inspect}"
  end

  # A loop whose spine round has answered, as the wake and the hooks find it.
  def settled_loop
    agent_loop = seed(model("r1"))
    stamp!(agent_loop, "r1")
    agent_loop.update!(status: "running")
    agent_loop
  end

  def reads(node) = [node.input_from_node_keys, node.result_from_node_keys]

  def start!(agent_loop)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: agent_loop.creating_user))
    schedule_loop!(agent_loop)
  end

  test "ExpandRound's continuation continues the round and reads its paired calls" do
    agent_loop = seed(model("round1", "tools" => [READ_TOOL]))
    start!(agent_loop)
    run_loop_round!(agent_loop, sse_success("calling", tool_calls: [
      { id: "call_a", name: "read_file", arguments: '{"path":"a"}' },
      { id: "call_b", name: "read_file", arguments: '{"path":"b"}' },
    ]))

    assert_equal [%w[round1 r1t0 r1t1], nil], reads(node(agent_loop, "r1"))
    assert_equal "round", node(agent_loop, "r1").continuation_source
  end

  # The wake continues the spine's tail and reads every pending tip beside it: an ordinary tip as
  # material, a stage's value — behind a boundary the wake is not inside — as a result.
  test "the wake reads the spine's tail and its tips; the plant reads its source alone" do
    agent_loop = settled_loop
    kernel!(agent_loop, [Step::Tool.new(key: "bg", name: "shell", detached: true),
                         Step::Script.new(key: "s", script: "return 1;", detached: true)], Tip.seed("branch"))
    kernel!(agent_loop, [Step::Tool.new(key: "leaf", name: "shell")],
      AgentLoops::KernelTool.branch_tip(node(agent_loop, "s")), expansion_parent: node(agent_loop, "s"), replaces: "s")
    %w[bg s leaf].each { |key| stamp!(agent_loop, key) }

    assert_equal "w1", AgentLoops::WakeContinuation.call(agent_loop: agent_loop.reload)
    assert_equal [%w[r1 bg], %w[leaf]], reads(node(agent_loop, "w1"))

    stamp!(agent_loop, "w1")
    assert_equal "w2", AgentLoops::WakeContinuation.plant(agent_loop: agent_loop.reload, source: node(agent_loop, "w1"))
    assert_equal [%w[w1], nil], reads(node(agent_loop, "w2"))
  end

  test "a lifecycle hook's continuation continues its source and waits on the hook without reading it" do
    agent_loop = settled_loop
    kernel!(agent_loop, [Step::Tool.new(key: "h1", name: "shell")], Tip.seed("branch"))
    stamp!(agent_loop, "h1")
    r1 = node(agent_loop, "r1")
    AgentLoops::LifecycleHooks.append_continuation(agent_loop, r1, r1, node(agent_loop, "h1"), "keep going")

    continuation = node(agent_loop, "w1")
    assert_equal [%w[r1], nil], reads(continuation)
    assert_equal %w[h1], continuation.sources.map(&:node_key)
  end

  # `KernelTool.branch_tip` is the most-used author: compose, a stage's steps, `task`, `ask`,
  # `wait`, `spawn` and delegation all root their branch there, and every one of them is fresh.
  test "every branch KernelTool.branch_tip roots is fresh" do
    agent_loop = settled_loop
    kernel!(agent_loop, [Step::Tool.new(key: "call", name: "shell")], Tip.seed("round"))
    call = node(agent_loop, "call")
    kernel!(agent_loop, [Step::Model.new(key: "waited", model: MOCK_MODEL, prompt: "p")],
      AgentLoops::KernelTool.branch_tip(call))
    kernel!(agent_loop, [Step::Model.new(key: "background", model: MOCK_MODEL, prompt: "p")],
      AgentLoops::KernelTool.branch_tip(call).with(detached: true))

    %w[waited background].each do |key|
      assert_equal [nil, nil], reads(node(agent_loop, key)), key
      assert_equal "branch", node(agent_loop, key).continuation_source
      assert_equal %w[call], node(agent_loop, key).sources.map(&:node_key), "it waits on its call"
    end
  end

  # A graph verb a composed graph calls (`g.tool({name: "task"})`) has no provider pairing: the
  # step after it is an authored one, never the driver's continuation, so the work the call starts
  # is never spliced into what that step reads. A waited `task` stands in for its call — a step
  # that named the call reads the delegate's answer — and a waited `compose` is placed as
  # background work, whose results come back through the one delivery set.
  test "a composed task or compose call under wait: true hands the authored step after it nothing to read" do
    agent_loop = settled_loop
    branch = AgentLoops::KernelTool.branch_tip(node(agent_loop, "r1")).with(detached: true)
    kernel!(agent_loop, [
      Step::Tool.new(key: "tc", name: "task", input: { "prompt" => "sub", "wait" => true }),
      Step::Model.new(key: "after-task", model: MOCK_MODEL, prompt: "p"),
      Step::Model.new(key: "named", model: MOCK_MODEL, prompt: "p", results: %w[tc]),
    ], branch)
    kernel!(agent_loop, [
      Step::Tool.new(key: "cc", name: "compose", input: { "script" => 'g.model({prompt: "inner"});', "wait" => true }),
      Step::Model.new(key: "after-compose", model: MOCK_MODEL, prompt: "p"),
    ], branch)
    %w[tc cc].each { |key| stamp!(agent_loop, key, status: "running") }

    AgentLoops::TaskTool::Run.call(node: node(agent_loop, "tc"))
    AgentLoops::Compose::Run.call(node: node(agent_loop, "cc"))

    assert_equal [nil, nil], reads(node(agent_loop, "after-task"))
    assert_equal [nil, %w[tc-model-1]], reads(node(agent_loop, "named")), "the delegate stands for its call"
    assert_includes node(agent_loop, "after-task").sources.map(&:node_key), "tc-model-1", "and is waited on"
    assert_equal [nil, nil], reads(node(agent_loop, "after-compose"))
    inner = agent_loop.agent_loop_nodes.find_by!(expansion_parent_id: node(agent_loop, "cc").id)
    assert_predicate inner, :detached?, "a composed compose places background work"
    assert_not_includes node(agent_loop, "after-compose").sources.map(&:node_key), inner.node_key
  end

  test "a lifecycle hook's tool hands its head a wait and nothing to read" do
    agent_loop = settled_loop
    r1 = node(agent_loop, "r1")
    kernel!(agent_loop, [Step.inheriting(r1, key: "r2", prompt: "next")], kernel_tip(r1, [r1], [], "round"))
    head = node(agent_loop, "r2")
    before = reads(head)

    hook = AgentLoops::LifecycleHooks.find_or_append(agent_loop, "turn_start", head,
      policy: { "tool" => "shell", "timeout_ms" => 60_000 }, head: head)

    assert_equal before, reads(head.reload), "the head reads what it read before"
    assert_includes head.sources.map(&:node_key), hook.node_key, "and waits on the hook"
  end

  # THE ARM'S SUMMARIZER: a branch root the round waits on. It reads nothing by position — its
  # history is its own input — and the round finds the summary through its mark, never its reads.
  test "the arm's summarizer reads nothing by position, and its head gains a wait and nothing to read" do
    agent_loop = seed(model("round1", "instructions" => "be useful", "prompt" => "start the work #{BULK}"),
      model("round2", "prompt" => "keep going #{BULK}"))
    start!(agent_loop)
    run_loop_round!(agent_loop, sse_success("here is what I found"))

    round2 = node(agent_loop, "round2")
    assert_equal "k1", round2.compaction["summary_source"], "the wall armed the repair"
    assert_equal [%w[round1], nil], reads(round2), "the round reads what it read before"
    assert_includes round2.sources.map(&:node_key), "k1", "and waits on the summarizer"
    assert_equal [nil, nil], reads(node(agent_loop, "k1"))

    run_loop_round!(agent_loop, sse_success("THE SUMMARY"))
    assert_equal "k1", node(agent_loop, "round2").arrived_summary.node_key
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
    agent_loop = seed(model("round1", "instructions" => "be useful", "prompt" => BULK),
      model("round2", "prompt" => BULK, "compaction" => { "mode" => "delegate", "tool_name" => TOOL }),
      creating_user: @agent)
    start!(agent_loop)
    run_loop_round!(agent_loop, sse_success("here is what I found"))
    claimed = Executors::Claim.call(Executors::Claim::Command.new(agent_loop: agent_loop, task_key: "k1", executor: address))
    assert_predicate claimed, :accepted?, claimed.outcome.inspect
    AgentLoopNode.where(id: node(agent_loop, "k1").id).update_all(await_started_at: 2.hours.ago)
    AgentLoops::Parks::TimeoutSweep.call

    round2 = node(agent_loop, "round2")
    assert_equal "k2", round2.compaction["summary_source"], "the fallback replaced the expired delegate"
    assert_equal [%w[round1], nil], reads(round2)
    assert_includes round2.sources.map(&:node_key), "k2"
    assert_equal [nil, nil], reads(node(agent_loop, "k2"))
  end
end
