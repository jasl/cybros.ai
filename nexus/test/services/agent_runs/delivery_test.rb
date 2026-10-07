require "test_helper"

# WHAT COMES BACK TO THE CALLER, and WHEN: every result no step reads — one set for a waited head
# and for the wake — delivered once the chain it belongs to has settled. A wait defers delivery and
# never consumes it; a race's barrier stands for every row in its arms, an expansion for the row it
# replaced, and a stage's insides stay behind its boundary.
class AgentRuns::DeliveryTest < ActiveSupport::TestCase
  Step = AgentRuns::Tasks::Step
  Tip = AgentRuns::Tasks::Tip

  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
    fresh_loop
  end

  # A loop whose mainline round has answered, as the wake finds it.
  def fresh_loop
    @agent_run = seed(model("r1"))
    stamp!("r1")
    @agent_run.update!(status: "running")
  end

  def node(key) = @agent_run.agent_run_tasks.find_by!(node_key: key)

  # Stamped, not transitioned: only the settlements matter here.
  def stamp!(key, status: "completed", **columns)
    AgentRunTask.where(id: node(key).id).update_all(status: status, completed_at: Time.current, **columns)
  end

  def settle!(key)
    stamp!(key)
    AgentRuns::Release.settled(node(key))
  end

  def kernel!(steps, tip, **command)
    result = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: @agent_run, steps: steps, tip: tip, origin: "kernel", **command
    ))
    assert_predicate result, :applied?, "#{result.outcome}: #{result.errors.inspect}"
  end

  def background = Tip.seed("branch").with(detached: true)

  def tool_step(key, **over) = Step::Tool.new(key: key, name: "shell", **over)
  def model_step(key, **over) = Step::Model.new(key: key, model: MOCK_MODEL, prompt: "p", **over)

  def pending = AgentRuns::WakeContinuation.undelivered(@agent_run.reload).map(&:node_key)

  # The same step sequences can splice under a waiting continuation or
  # run detached from their own branch tip; both paths report the same results.
  def scripts
    {
      "a model, then a tool" => -> { [model_step("m1"), tool_step("t1")] },
      "a script ending on a group whose model names the tool before it" => -> {
        [tool_step("t0"), Step::Parallel.new(members: [model_step("m1", results: %w[t0]), tool_step("t2")])]
      },
    }
  end

  test "what no step reads comes back: the waited head and the wake read one set" do
    expected = { "a model, then a tool" => %w[m1 t1],
                 "a script ending on a group whose model names the tool before it" => %w[m1 t2] }
    scripts.each do |label, steps|
      fresh_loop
      kernel!([model_step("head")], kernel_tip(node("r1"), [node("r1")], [], "round"))
      kernel!(steps.call, Tip.seed("branch"), head: "head")
      head = node("head")
      read = Array(head.input_from_node_keys) - %w[r1] + Array(head.result_from_node_keys)

      fresh_loop
      kernel!(steps.call, background)
      @agent_run.agent_run_tasks.where.not(node_key: "r1").order(:id).pluck(:node_key).each { |key| stamp!(key) }

      assert_equal expected.fetch(label), read, label
      assert_equal read.sort, pending.sort, "#{label}: one set, key for key"
    end
  end

  # A wait no longer consumes, so without the timing rule a detached `t1; t2; m` would come back a
  # step at a time — one paid mainline round each — instead of once.
  test "a chain is delivered whole when its last step settles" do
    kernel!([tool_step("t1"), tool_step("t2"), model_step("m")], background)
    settle!("t1")
    assert_empty pending, "t2 and m are still live"
    settle!("t2")
    assert_empty pending, "m is still live"
    settle!("m")

    assert_equal %w[t1 t2 m], pending
    assert_equal "w1", AgentRuns::WakeContinuation.call(agent_run: @agent_run.reload)
    assert_equal %w[r1 t1 t2 m], node("w1").input_from_node_keys, "in one wake"
    assert_empty pending
  end

  test "a race nobody names comes back as its selection; its arms' steps never do, winner or loser" do
    kernel!([Step::Parallel.new(members: [[tool_step("t1"), model_step("m1")], [tool_step("t2"), model_step("m2")]],
      until: "any", key: "race", on_failure: "absorb")], background)
    assert_equal %w[race] * 4, %w[t1 m1 t2 m2].map { |key| node(key).barrier_node.node_key }
    settle!("t1")
    settle!("m1")

    assert_equal "completed", node("race").status
    assert_equal %w[canceled canceled], %w[t2 m2].map { |key| node(key).status }
    assert_equal %w[m1], pending, "the barrier comes back as its winner, never as an arm's own step"
    assert_equal "w1", AgentRuns::WakeContinuation.call(agent_run: @agent_run.reload)
    assert_equal %w[r1 m1], node("w1").input_from_node_keys
    assert_empty pending
  end

  # A run-out loser's round with calls is replaced by its fan and continuation (ExpandRound's
  # shape); what it expands into stays an arm of the race, however late it answers.
  test "a run-out loser finishing late does not come back" do
    kernel!([Step::Parallel.new(members: [model_step("a"), model_step("b")],
      until: "any", losers: "run_out", key: "race", on_failure: "absorb")], background)
    settle!("a")
    assert_equal "completed", node("race").status
    stamp!("b")
    b = node("b")
    kernel!([Step::Parallel.new(members: [tool_step("b-call", tool_call_id: "c1", on_failure: "absorb")]),
             Step.inheriting(b, key: "b2")],
      Tip.new(mainline: known(b), waits: [known(b)], reads: [], mark: b.continuation_source, detached: true),
      origin: "model", expansion_parent: b, replaces: "b")
    assert_equal %w[race race], %w[b-call b2].map { |key| node(key).barrier_node.node_key },
      "the loser's late rounds inherit its barrier"

    settle!("b-call")
    settle!("b2")
    assert_equal %w[a], pending
  end

  # A settled race's selection stands for its arms, so a loser still running out holds back nothing
  # the chain delivers beside the race: the set comes back whole, at one moment.
  test "a race's loser still running holds back nothing written before the race" do
    kernel!([tool_step("t0"), Step::Parallel.new(members: [model_step("a"), model_step("b")],
      until: "any", losers: "run_out", key: "race", on_failure: "absorb")], background)
    settle!("t0")
    settle!("a")
    assert_equal "completed", node("race").status
    assert_equal "queued", node("b").status, "the loser runs out"

    assert_equal %w[t0 a], pending
  end

  # A person's retry re-runs the loser's own row, which keeps its barrier: the race's selection is
  # the one it captured, so the loser's late answer never comes back beside the winner.
  test "a race's failed loser retried after the race settled never comes back" do
    kernel!([Step::Parallel.new(members: [tool_step("a"), tool_step("b")],
      until: "any", losers: "run_out", key: "race", on_failure: "absorb")], background)
    settle!("a")
    assert_equal "completed", node("race").status
    AgentRuns::FailNode.call(agent_run: @agent_run, node: node("b"), error_key: "tool_execution_failed", worklist: [])
    retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: @agent_run.reload, task_key: "b", acting_user: @human
    ))
    assert_predicate retried, :accepted?, retried.outcome.inspect
    settle!("b")

    assert_equal "race", node("b").barrier_node.node_key
    assert_equal %w[a], pending
  end

  # A step its author detached inside a race's arm is neither an arm's exit nor a loser the race
  # stops: the barrier does not stand for it, so it comes back on its own once it settles.
  test "a step detached inside a race's arm comes back when it settles" do
    grow!(@agent_run, parallel([tool("a"), detached(tool("d"))], tool("b"),
      until: "any", key: "race", on_failure: "absorb"), tool("after"))
    assert_nil node("d").barrier_node, "the barrier stands for its arms alone"
    settle!("a")
    settle!("d")

    assert_equal "canceled", node("b").status
    assert_equal %w[d], pending
  end

  test "an operation owner returns its own value while nested child results stay internal" do
    kernel!([tool_step("s")], background)
    kernel!([tool_step("i1"), tool_step("s2"), tool_step("i3")],
      background, expansion_parent: node("s"), child_work: true)
    kernel!([tool_step("j1"), tool_step("jleaf")],
      background, expansion_parent: node("s2"), child_work: true)
    { "s" => %w[i1 s2 i3], "s2" => %w[j1 jleaf] }.each do |owner, children|
      request = { "kind" => "steps", "input" => children.map { |key| { "tool" => { "key" => key, "name" => "shell" } } } }
      node(owner).task_operations.create!(operation_key: "children", kind: "steps", request: request,
        request_digest: Nexus::CanonicalJson.digest(request), position: 1,
        response: { "receipt" => { "task_keys" => children, "result_task_keys" => children } })
    end
    %w[s s2 i1 j1 jleaf i3].each { |key| stamp!(key) }

    assert_equal %w[s], pending
  end

  # An authored ask, wait or spawn tool step expands under the call's own key:
  # the call's "Asked…" acknowledgement is replaced by the answer, and only the answer comes back —
  # for a spawn, its delegation, which owns the child's one report beside the await's short wait.
  test "a composed ask, wait and spawn call are consumed by their expansion" do
    kernel!([tool_step("ask-call", name: "ask", input: { "prompt" => "which db?" })], background)
    stamp!("ask-call", status: "running")
    AgentRuns::Asks::Run.call(node: node("ask-call"))
    kernel!([Step::Ask.new(key: "external", prompt: "?")], Tip.seed("round"))
    kernel!([tool_step("wait-call", name: "wait", input: { "task" => "external" })], background)
    stamp!("wait-call", status: "running")
    AgentRuns::WaitTool::Run.call(node: node("wait-call"))
    # The spawn's expansion is its await under the call (Spawn::Run#append_await) and its delegation
    # (Delegations.prepare), without the child conversation.
    kernel!([tool_step("spawn-call", name: "spawn", input: { "prompt" => "go" })], background)
    kernel!([Step::Ask.new(key: "spawn-call-spawn-1", prompt: "go", on_failure: "absorb")],
      AgentRuns::KernelTool.branch_tip(node("spawn-call")), holder: :kernel,
      expansion_parent: node("spawn-call"), replaces: "spawn-call")
    AgentRuns::Delegations.prepare(call: node("spawn-call"))
    %w[ask-call wait-call spawn-call ask-call-ask-1 wait-call-wait-1 spawn-call-spawn-1 spawn-call-delegation-1
       external].each { |key| stamp!(key) }

    assert_equal %w[ask-call-ask-1 spawn-call-delegation-1 wait-call-wait-1], pending.sort,
      "the answer comes back; the call it replaced never does, nor a spawn's short wait"
  end

  # Consumption is naming — the recorded edge — whatever the reader then did.
  test "a result a failed reader named is consumed" do
    kernel!([tool_step("t1"), model_step("m", results: %w[t1], on_failure: "absorb")], background)
    settle!("t1")
    stamp!("m", status: "failed", error_key: "unknown_model")

    assert_equal %w[m], pending
  end
end
