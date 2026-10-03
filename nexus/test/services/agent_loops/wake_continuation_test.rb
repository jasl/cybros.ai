require "test_helper"

# The wake's tip: it WAITS only on the tips that answered and READS every
# undelivered one — the kernel's `waits ≠ reads` privilege — so a skipped
# tip never makes the wake round born skipped, and the spine it continues
# from is never a branch, the compaction summarizer included.
class AgentLoops::WakeContinuationTest < ActiveSupport::TestCase
  Step = AgentLoops::Tasks::Step
  Tip = AgentLoops::Tasks::Tip

  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
    @agent_loop = seed(model("r1"))
    stamp!("r1")
    @agent_loop.update!(status: "running")
  end

  def node(key) = @agent_loop.agent_loop_nodes.find_by!(node_key: key)

  # Stamped, not transitioned: only the settlements matter here.
  def stamp!(key, status: "completed", **columns)
    AgentLoopNode.where(id: node(key).id).update_all(status: status, completed_at: Time.current, **columns)
  end

  def kernel!(steps, tip)
    result = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
      agent_loop: @agent_loop, steps: steps, tip: tip, origin: "kernel"
    ))
    assert_predicate result, :applied?, result.outcome.inspect
  end

  # Background roots, as a script places them: branch-marked, detached.
  def detach_tips!(*keys)
    kernel!(keys.map { |key| Step::Tool.new(key: key, name: "shell", detached: true) }, Tip.seed("branch"))
  end

  test "the wake waits on the tips that answered and reads every pending one" do
    detach_tips!("bg1", "bg2", "bg3")
    stamp!("bg1")
    stamp!("bg2", status: "canceled")
    stamp!("bg3", status: "failed", on_failure: "absorb")

    assert_equal "w1", AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload)

    wake = node("w1")
    assert_equal "queued", wake.status, "a skipped tip does not make the wake round born skipped"
    assert_equal %w[bg1 bg3], wake.sources.map(&:node_key), "success and resolved are waited on"
    assert_equal %w[r1 bg1 bg2 bg3], wake.input_from_node_keys, "the spine's tail, then every tip"
    assert_equal 0, wake.remaining_dependencies
    assert_equal "round", wake.continuation_source
    assert_equal "w1", @agent_loop.reload.deliverable_node.node_key, "the answer moves with the round"

    composed = AgentLoops::InputComposition.call(node: wake, input: nil)
    assert_predicate composed, :composed?, composed.refusal.inspect
    assert_equal [
      "<task_result task=\"bg1\" status=\"completed\">\n<call>shell {}</call>\n#{AgentLoops::TaskResultEnvelope::EMPTY}\n</task_result>",
      "<task_result task=\"bg2\" status=\"canceled\">\n<call>shell {}</call>\n#{AgentLoops::TaskResultEnvelope::EMPTY}\n</task_result>",
      "<task_result task=\"bg3\" status=\"failed\">\n<call>shell {}</call>\n#{AgentLoops::TaskResultEnvelope::EMPTY}\n</task_result>",
    ], composed.elements.map { |element| element.parts.first.text },
      "every tip is delivered in the envelope with its status - a skipped one included, never silently"
  end

  test "delivery is level-triggered: a second wake finds the tips read and appends nothing" do
    detach_tips!("bg1")
    stamp!("bg1")
    AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload)

    assert_nil AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload)
    assert_nil AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload)
  end

  test "a detached graph ending in a race delivers its winning result once" do
    kernel!([Step::Parallel.new(
      members: [Step::Tool.new(key: "a", name: "shell"), Step::Tool.new(key: "b", name: "shell")],
      until: "any", key: "race", on_failure: "absorb"
    )], Tip.seed("branch").with(detached: true))
    stamp!("a")
    AgentLoops::Release.settled(node("a"))

    assert_equal "completed", node("race").status
    assert_equal "canceled", node("b").status
    assert_equal "w1", AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload)
    assert_equal %w[r1 a], node("w1").input_from_node_keys
    assert_empty AgentLoops::WakeContinuation.undelivered(@agent_loop.reload)
  end

  test "a detached race does not report a run out loser that succeeds later" do
    kernel!([Step::Parallel.new(
      members: [Step::Tool.new(key: "a", name: "shell"), Step::Tool.new(key: "b", name: "shell")],
      until: "any", losers: "run_out", key: "race", on_failure: "absorb"
    )], Tip.seed("branch").with(detached: true))
    stamp!("a")
    AgentLoops::Release.settled(node("a"))
    stamp!("b")
    AgentLoops::Release.settled(node("b"))

    assert_equal "w1", AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload)
    assert_equal %w[r1 a], node("w1").input_from_node_keys
    assert_empty AgentLoops::WakeContinuation.undelivered(@agent_loop.reload)
  end

  test "a detached nested quorum delivers each winning branch without its consumed history" do
    inner = Step::Parallel.new(
      members: [Step::Tool.new(key: "a", name: "shell"), Step::Tool.new(key: "b", name: "shell")],
      until: "any", key: "inner", on_failure: "absorb"
    )
    kernel!([Step::Parallel.new(members: [inner, [
      Step::Tool.new(key: "notes", name: "shell"),
      Step::Model.new(key: "review", prompt: "Review the notes.", model: MOCK_MODEL),
    ], Step::Tool.new(key: "c", name: "shell")],
      until: 2, key: "outer", on_failure: "absorb")], Tip.seed("branch").with(detached: true))
    stamp!("a")
    AgentLoops::Release.settled(node("a"))
    assert_empty AgentLoops::WakeContinuation.undelivered(@agent_loop.reload)
    stamp!("notes")
    AgentLoops::Release.settled(node("notes"))
    stamp!("review")
    AgentLoops::Release.settled(node("review"))

    assert_equal "w1", AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload)
    assert_equal %w[r1 a review], node("w1").input_from_node_keys
    assert_empty AgentLoops::WakeContinuation.undelivered(@agent_loop.reload)
  end

  test "a detached starved race reports its failure instead of silently completing" do
    kernel!([Step::Parallel.new(members: [
      Step::Tool.new(key: "a", name: "shell", on_failure: "absorb"),
      Step::Tool.new(key: "b", name: "shell", on_failure: "absorb"),
    ], until: "any", key: "race", on_failure: "absorb")], Tip.seed("branch").with(detached: true))
    %w[a b].each do |key|
      stamp!(key, status: "failed", error_key: "tool_failed")
      AgentLoops::Release.settled(node(key))
    end

    assert_equal "failed", node("race").status
    assert_equal "w1", AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload)
    assert_equal %w[r1 race], node("w1").input_from_node_keys
    composed = AgentLoops::InputComposition.call(node: node("w1"), input: nil)
    assert_predicate composed, :composed?, composed.refusal.inspect
    assert_equal ["<task_result task=\"race\" status=\"failed\">\njoin_starved\n</task_result>"],
      composed.elements.map { |element| element.parts.first.text }
    assert_empty AgentLoops::WakeContinuation.undelivered(@agent_loop.reload)
  end

  # A FAILED RACE hands its reader what it captured before failing, then its own failure — the one
  # selection the wait tool, a stage and a model step read too.
  test "a detached failed quorum delivers its partial winner, then its failure" do
    kernel!([Step::Parallel.new(members: %w[a b c].map { |key| Step::Tool.new(key: key, name: "shell") },
      until: 2, key: "race", on_failure: "absorb")], Tip.seed("branch").with(detached: true))
    stamp!("a")
    AgentLoops::Release.settled(node("a"))
    %w[b c].each do |key|
      stamp!(key, status: "failed", error_key: "tool_failed")
      AgentLoops::Release.settled(node(key))
    end

    assert_equal %w[failed quorum_unreachable], node("race").values_at(:status, :error_key)
    assert_equal "w1", AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload)
    assert_equal %w[r1 a race], node("w1").input_from_node_keys
    composed = AgentLoops::InputComposition.call(node: node("w1"), input: nil)
    assert_predicate composed, :composed?, composed.refusal.inspect
    assert_equal [
      "<task_result task=\"a\" status=\"completed\">\n<call>shell {}</call>\n#{AgentLoops::TaskResultEnvelope::EMPTY}\n</task_result>",
      "<task_result task=\"race\" status=\"failed\">\nquorum_unreachable\n</task_result>",
    ], composed.elements.map { |element| element.parts.first.text }
    assert_empty AgentLoops::WakeContinuation.undelivered(@agent_loop.reload)
  end

  # The sibling of the next test: the same barrier is never MATERIAL, but named as a RESULT it
  # reads what it selected — the winner, as result material, and never the barrier itself.
  test "a successful barrier named as a result reads what it selected" do
    kernel!([Step::Parallel.new(members: [Step::Tool.new(key: "a", name: "shell"), Step::Tool.new(key: "b", name: "shell")],
      until: "any", key: "race")], Tip.seed("branch").with(detached: true))
    stamp!("a")
    AgentLoops::Release.settled(node("a"))
    race = AgentLoops::Tasks::Known.of(node("race"), result_only: true)

    kernel!([Step::Model.new(key: "reader", model: MOCK_MODEL)],
      kernel_tip(node("r1"), [node("race")], [], "round").with(reads: [race]))
    assert_equal ["race"], node("reader").result_from_node_keys
    composed = AgentLoops::InputComposition.call(node: node("reader"), input: nil)
    assert_predicate composed, :composed?, composed.refusal.inspect
    assert_equal ["<task_result task=\"a\" status=\"completed\">\n<call>shell {}</call>\n" \
                  "#{AgentLoops::TaskResultEnvelope::EMPTY}\n</task_result>"],
      composed.elements.map { |element| element.parts.first.text }
  end

  test "a successful barrier remains unreadable as a task result" do
    kernel!([Step::Parallel.new(members: [Step::Tool.new(key: "a", name: "shell")],
      until: "any", key: "race")], Tip.seed("branch").with(detached: true))
    stamp!("a")
    AgentLoops::Release.settled(node("a"))

    result = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
      agent_loop: @agent_loop, steps: [Step::Model.new(key: "bad", model: MOCK_MODEL)],
      tip: kernel_tip(node("r1"), [node("race")], [node("race")], "round"), origin: "kernel"
    ))

    assert_equal :invalid_input_from_source, result.outcome
    refute @agent_loop.agent_loop_nodes.exists?(node_key: "bad")
  end

  test "rechecking delivered races batches their winning sources regardless of breadth" do
    15.times do |index|
      key = "answer-#{index}"
      kernel!([Step::Parallel.new(members: [Step::Tool.new(key: key, name: "shell")],
        until: "any", key: "race-#{index}")], Tip.seed("branch").with(detached: true))
      stamp!(key)
      AgentLoops::Release.settled(node(key))
      wake = AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload)
      assert_not_nil wake
      stamp!(wake)

      next unless [0, 14].include?(index)

      # The sink query with its consumer anti-joins, the owners query over
      # what it left, the readiness walk, one batched winner read, and the
      # existing read-set projection: old races add rows, never one source
      # query per barrier.
      assert_queries_count(5) do
        assert_empty AgentLoops::WakeContinuation.undelivered(@agent_loop)
      end
    end
  end

  # A WAIT DEFERS DELIVERY, IT NEVER CONSUMES: the tools a written chain waited on come back with
  # the step that ended it, once it settles; a tool a later step named is read there, not here.
  test "a tool chain's unread tips are delivered when the chain ends; a tool a later step named is not" do
    kernel!([Step::Tool.new(key: "t1", name: "shell"), Step::Tool.new(key: "t2", name: "shell"),
             Step::Model.new(key: "m", model: MOCK_MODEL, prompt: "p", results: %w[t2])],
      Tip.seed("branch").with(detached: true))
    %w[t1 t2].each do |key|
      stamp!(key)
      AgentLoops::Release.settled(node(key))
    end
    assert_nil AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload), "m is still live"

    stamp!("m")
    assert_equal "w1", AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload)
    assert_equal %w[r1 t1 m], node("w1").input_from_node_keys
    assert_empty AgentLoops::WakeContinuation.undelivered(@agent_loop.reload)
  end

  test "the wake stays blocked while a spine round is live, and never continues from a branch" do
    detach_tips!("bg1")
    stamp!("bg1")
    kernel!([Step::Model.new(key: "b", model: MOCK_MODEL, prompt: "aside")], Tip.seed("branch"))
    stamp!("b")
    assert_equal "r1", @agent_loop.spine_tail.node_key, "a newer branch-marked round is not the tail"

    kernel!([Step::Model.new(key: "r2", model: MOCK_MODEL, prompt: "next")],
      kernel_tip(node("r1"), [node("r1")], [], "round"))
    assert_predicate @agent_loop, :spine_live?
    assert_nil AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload),
      "a queued spine round's request is not sealed yet, so nothing is delivered before it"

    stamp!("r2")
    assert_equal "w1", AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload)
    assert_equal %w[r2 bg1], node("w1").input_from_node_keys, "the wake continues from the chain's tail"
  end

  # The drain is acceptance: one `input_accepted{origin: task_result}` item per tip the wake READ —
  # a skipped tip included, it is delivered too — on the loop's host feed, in the append's own
  # transaction; the plant reads no tip and narrates nothing.
  test "the wake narrates one input_accepted item per tip it reads; the plant narrates none" do
    detach_tips!("bg1", "bg2")
    stamp!("bg1")
    stamp!("bg2", status: "canceled")
    assert_equal "w1", AgentLoops::WakeContinuation.call(agent_loop: @agent_loop.reload)

    items = @agent_loop.host.conversation_event_items.where(item_type: "input_accepted").order(:sequence)
    assert_equal [
      { "origin" => "task_result", "agent_loop_public_id" => @agent_loop.public_id, "task_key" => "bg1" },
      { "origin" => "task_result", "agent_loop_public_id" => @agent_loop.public_id, "task_key" => "bg2" },
    ], items.map(&:payload)

    stamp!("w1")
    assert_equal "w2", AgentLoops::WakeContinuation.plant(agent_loop: @agent_loop.reload, source: node("w1"))
    assert_equal 2, @agent_loop.host.conversation_event_items.where(item_type: "input_accepted").count,
      "level-triggered and once: the read tips are spliced, the plant reads none"
  end

  test "the plant reads its source only and hangs off nothing" do
    assert_equal "w1", AgentLoops::WakeContinuation.plant(agent_loop: @agent_loop.reload, source: node("r1"))

    plant = node("w1")
    assert_equal ["r1"], plant.input_from_node_keys
    assert_empty plant.sources
    assert_equal 0, plant.remaining_dependencies
  end
end
