require "test_helper"

# The one append door through the real chain: the tip is derived under the
# lock, the lowering places written order, the deliverable follows the tip
# by one rule for every author, and the concurrency fences (receipt, digest,
# CAS) answer under the lock.
class AgentLoops::AppendTest < ActiveSupport::TestCase
  Append = AgentLoops::Tasks::Append
  Tip = AgentLoops::Tasks::Tip
  Step = AgentLoops::Tasks::Step

  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
    @agent_loop = seed(model("seed"))
  end

  def node(key) = @agent_loop.agent_loop_nodes.find_by!(node_key: key)

  # Stamped, not transitioned: a round reaches `completed` only by running,
  # and these fixtures only need the graph's settlements to answer.
  def settle!(key, status: "completed", **columns)
    node(key).update_columns(status: status, completed_at: Time.current, **columns)
  end

  # A park that a resolve may answer: dispatched, on its clock.
  def park!(key)
    node(key).update_columns(status: "dispatched", started_at: Time.current, await_started_at: Time.current)
  end

  def kernel!(steps, tip, origin: "model", **command)
    result = Append.call(Append::Command.kernel(agent_loop: @agent_loop, steps: steps, tip: tip, origin: origin, **command))
    assert_predicate result, :applied?, "#{result.outcome}: #{result.errors.inspect}"
    result
  end

  def deliverable_key = @agent_loop.reload.deliverable_node.node_key
  def tip_keys(tip) = [tip.spine&.key, tip.waits.map(&:key), tip.reads.map(&:key)]
  def boundary = tip_keys(Append.boundary_tip(@agent_loop.reload))

  test "completion read replacement retains the finite wait dependency and leaves sealed readers alone" do
    settle!("seed")
    # A waited spawn: the round's call, its continuation, and the kernel-held await spliced between.
    kernel!([Step::Parallel.new(members: [Step::Tool.new(key: "call", name: "spawn", tool_call_id: "c")]),
             Step.inheriting(node("seed"), key: "next")],
      kernel_tip(node("seed"), [node("seed")], [], "round"))
    kernel!([Step::Ask.new(key: "wait", prompt: "child", on_failure: "absorb")],
      kernel_tip(nil, [node("call")], [], "branch"), holder: :kernel, expansion_parent: node("call"), head: "next")
    kernel!([Step::Delegation.new(key: "completion")], Tip.seed("branch").with(detached: true), origin: "kernel")
    kernel!([Step.inheriting(node("seed"), key: "sealed")],
      kernel_tip(node("seed"), [], [node("wait")], "branch"))
    node("sealed").update_columns(status: "running", started_at: Time.current)
    dependencies = node("next").sources.map(&:node_key)
    countdown = node("next").remaining_dependencies

    @agent_loop.with_lock do
      2.times { Append.replace_reads(agent_loop: @agent_loop, replaces: "wait", reads: ["completion"]) }
    end

    assert_equal %w[seed call completion], node("next").input_from_node_keys
    assert_equal dependencies, node("next").sources.map(&:node_key)
    assert_equal countdown, node("next").remaining_dependencies
    assert_equal %w[seed wait], node("sealed").input_from_node_keys
    assert_empty AgentLoops::WakeContinuation.undelivered(@agent_loop)
  end

  # EVERY ROW CARRIES ITS WRITER: the append door stamps `author` (a principal's write, pre-approved
  # by its origin), a kernel command names `model` (a round's fan, a composed graph) or `kernel` (a
  # plant, a summarizer, an ask) — required, since an unlabelled kernel writer would be a silent
  # grant at the approval stage. Rounds, joins and awaits carry it too: the column is a fact about
  # every row.
  test "every node carries authored_by from its writer, and a kernel command must name its origin" do
    @agent_loop = seed(model("plan"), parallel(tool("a"), tool("b")), ask("gate"))
    assert_equal %w[author author author author], %w[plan a b gate].map { |key| node(key).authored_by }

    seed_node = node("plan")
    kernel!([Step::Parallel.new(members: [Step::Tool.new(key: "r1t0", name: "x", tool_call_id: "c")]),
             Step.inheriting(seed_node, key: "r1")],
      kernel_tip(seed_node, [seed_node], [], "round"), origin: "model")
    assert_equal %w[model model], %w[r1t0 r1].map { |key| node(key).authored_by }

    kernel!([Step::Tool.new(key: "planted", name: "x")], Tip.seed("branch"), origin: "kernel")
    assert_equal "kernel", node("planted").authored_by

    assert_raises(ArgumentError) do
      Append::Command.kernel(agent_loop: @agent_loop, steps: [], tip: Tip.seed("branch"))
    end
    assert_raises(ArgumentError) do
      Append::Command.kernel(agent_loop: @agent_loop, steps: [], tip: Tip.seed("branch"), origin: "unrecognized")
    end
    assert_raises(ActiveRecord::ReadonlyAttributeError) { node("planted").update!(authored_by: "author") }
  end

  test "completion replacement preserves a failed race already among the reader's sources" do
    settle!("seed")
    kernel!([Step::Ask.new(key: "wait", prompt: "child", on_failure: "absorb")],
      kernel_tip(node("seed"), [node("seed")], [], "round"), holder: :kernel)
    kernel!([Step::Parallel.new(members: [Step::Tool.new(key: "failed", name: "x", on_failure: "absorb")],
      until: "any", key: "race", on_failure: "absorb")], Tip.seed("branch").with(detached: true))
    settle!("failed", status: "failed")
    AgentLoops::Release.settled(node("failed"))
    assert_equal "failed", node("race").status
    kernel!([Step.inheriting(node("seed"), key: "consumer")],
      kernel_tip(node("seed"), [node("wait")], [node("wait"), node("race")], "round"))
    kernel!([Step::Delegation.new(key: "completion")], Tip.seed("branch").with(detached: true), origin: "kernel")
    events = @agent_loop.conversation_event_items.where(item_type: "task_status")
      .where("payload ->> 'task_key' = ?", "consumer")

    assert_no_difference -> { events.count } do
      @agent_loop.with_lock do
        Append.replace_reads(agent_loop: @agent_loop, replaces: "wait", reads: ["completion"])
        raise ActiveRecord::Rollback
      end
    end
    assert_equal %w[seed wait race], node("consumer").input_from_node_keys
    @agent_loop.reload

    assert_difference -> { events.count }, 1 do
      @agent_loop.with_lock do
        Append.replace_reads(agent_loop: @agent_loop, replaces: "wait", reads: ["completion"])
      end
    end

    assert_equal %w[seed completion race], node("consumer").input_from_node_keys
    assert_equal ["wait"], node("consumer").sources.map(&:node_key)
  end

  # NO SILENT DEFAULT: the front door names the mode or creates nothing; the rule list is refused by
  # the one grammar; both ride the digest.
  test "Create refuses a nil approval_mode and a malformed approval_rules by name, and the digest carries both" do
    create = ->(**shell) {
      AgentLoops::Create.call(AgentLoops::Create::Command.new(
        workspace: @workspace, creating_user: @human, steps: [model("only")], billing_subject: nil,
        idempotency_key: nil, **shell
      ))
    }
    assert_equal :invalid_approval_mode, create.().outcome, "nil is not bypass"
    assert_equal :invalid_approval_mode, create.(approval_mode: "always").outcome
    assert_equal :invalid_approval_rules,
      create.(approval_mode: "rules", approval_rules: [{ "tool" => "x", "verdict" => "never" }]).outcome
    assert_equal :invalid_approval_rules, create.(approval_mode: "ask", approval_rules: "x").outcome

    rules = [{ "tool" => "x", "verdict" => "ask", "origin" => "author" }]
    born = create.(approval_mode: "rules", approval_rules: rules, idempotency_key: "k-1")
    assert_predicate born, :created?
    assert_equal %w[rules], [born.agent_loop.approval_mode]
    assert_equal rules, born.agent_loop.approval_rules
    assert_raises(ActiveRecord::ReadonlyAttributeError) { born.agent_loop.update!(approval_mode: "bypass") }

    assert_equal :idempotency_envelope_mismatch,
      create.(approval_mode: "ask", approval_rules: rules, idempotency_key: "k-1").outcome, "the mode is in the digest"
    assert_equal :idempotency_envelope_mismatch,
      create.(approval_mode: "rules", approval_rules: nil, idempotency_key: "k-1").outcome, "the rules are in the digest"
    assert_predicate create.(approval_mode: "rules", approval_rules: rules, idempotency_key: "k-1"), :replayed?
  end

  test "creation seeds the graph in written order, mints the countdowns, and ticks the seq once" do
    @agent_loop = seed(model("plan"), model("write"), tool("probe"))

    assert_equal 1, @agent_loop.revision
    assert_equal [0, 1, 1], %w[plan write probe].map { |key| node(key).remaining_dependencies }
    assert_equal ["plan"], node("write").input_from_node_keys, "write reads the round before it"
    assert_equal %w[round round], %w[plan write].map { |key| node(key).continuation_source },
      "an authored model step on the loop's path is the spine"
    assert_equal "probe", deliverable_key, "the answer is the envelope's end, whatever its kind"
    assert_equal "p", node("plan").content_bodies.sole.effective_text,
      "the prompt rides an owned content body, never a wide column"
  end

  test "the deliverable follows the tip by one rule, for every author and the seed" do
    assert_equal "seed", deliverable_key, "an authored seed designates its end by the nil clause"

    kernel_seed = AgentLoops::Create.call(AgentLoops::Create::Command.new(
      workspace: @workspace, creating_user: @human, steps: [model("only")], billing_subject: nil,
      idempotency_key: nil, approval_mode: "bypass"
    )).agent_loop
    fresh = AgentLoop.create!(workspace: @workspace, creating_user: @human, approval_mode: "bypass")
    fresh.create_conversation_event_cursor!(account: fresh.account)
    Append.call(Append::Command.kernel(agent_loop: fresh, tip: Tip.seed("round"), origin: "kernel",
      steps: [Step::Model.new(key: "r1", model: MOCK_MODEL)]))
    assert_equal "r1", fresh.reload.deliverable_node.node_key, "3a's kernel seed designates r1 by the same clause"
    assert_equal "only", kernel_seed.deliverable_node.node_key

    # ExpandRound from the deliverable round: the answer moves to the continuation.
    seed = node("seed")
    kernel!([Step::Parallel.new(members: [Step::Tool.new(key: "r1t0", name: "x", tool_call_id: "c")]),
             Step.inheriting(seed, key: "r1")],
      kernel_tip(seed, [seed], [], "round"))
    assert_equal "r1", deliverable_key
    assert_equal %w[seed r1t0], node("r1").input_from_node_keys

    # ExpandRound from a round that is NOT the deliverable leaves it alone.
    kernel!([Step::Parallel.new(members: [Step::Tool.new(key: "r2t0", name: "x", tool_call_id: "d")]),
             Step.inheriting(seed, key: "r2")],
      kernel_tip(seed, [seed], [], "branch"))
    assert_equal "r1", deliverable_key

    # The compaction arm's root and a compose call's subgraph: neither spine nor sole wait.
    settle!("r1t0")
    kernel!([Step::Model.new(key: "k1", model: MOCK_MODEL, prompt: "summarize", on_failure: "absorb")],
      Tip.seed("branch"), head: "r1", splice_reads: false)
    assert_equal "r1", deliverable_key
    assert_equal %w[r1t0 k1], node("r1").sources.map(&:node_key), "the arm's root is waited on, never read"
    assert_equal %w[seed r1t0], node("r1").input_from_node_keys

    # The wake from the spine tail moves it; the plant likewise.
    settle!("k1")
    settle!("r1")
    AgentLoopNode.where(id: node("r2t0").id).update_all(detached: true, status: "completed", completed_at: Time.current)
    tip = node("r2t0")
    kernel!([Step.inheriting(node("r1"), key: "w1")], kernel_tip(node("r1"), [tip], [tip], "round"))
    assert_equal "w1", deliverable_key
    assert_equal %w[r1 r2t0], node("w1").input_from_node_keys

    settle!("w1")
    assert_equal "w2", AgentLoops::WakeContinuation.plant(agent_loop: @agent_loop.reload, source: node("w1"))
    assert_equal "w2", deliverable_key
    assert_equal ["w1"], node("w2").input_from_node_keys, "a plant reads its source only"
    assert_empty node("w2").sources, "and hangs off nothing: the kernel's root privilege"

    # An authored envelope moves it to its end; one of only background steps leaves it.
    settle!("w2")
    grow!(@agent_loop, tool("t"), ask("q"))
    assert_equal "q", deliverable_key
    grow!(@agent_loop, detached(model("bg")))
    assert_equal "q", deliverable_key
  end

  # NOTHING CARRIES ACROSS APPENDS BY POSITION: the tip at the start of envelope N+1 is the loop's
  # spine tail and its answer, never a list of what envelope N left unread — a later envelope names
  # what it reads by key.
  test "the boundary pin: the tip after envelope N is the tip at the start of N+1, five shapes" do
    settle!("seed")
    assert_equal ["seed", ["seed"], []], boundary, "a completed spine round"

    grow!(@agent_loop, model("work-1"), ask("check-1"))
    settle!("work-1")
    park!("check-1")
    assert_equal ["work-1", ["check-1"], []], boundary, "an await hung off the chain's last round"

    grow!(@agent_loop, parallel(tool("a"), tool("b")), tool("c"), resolves: [{ "task" => "check-1", "content" => "yes" }])
    assert_equal ["work-1", ["c"], []], boundary, "a tool after an all fan"

    grow!(@agent_loop, parallel(tool("d"), tool("e"), tool("f"), until: "any", key: "p1"))
    assert_equal ["work-1", ["p1"], []], boundary, "a race"

    grow!(@agent_loop, parallel(model("m1"), model("m2")), model("final"))
    assert_equal %w[work-1], node("final").input_from_node_keys,
      "the follower continues the spine and reads nothing by position"
    assert_nil node("m1").input_from_node_keys, "a member is a fresh agent"
    settle!("final")
    assert_equal ["final", ["final"], []], boundary, "the follower of a fan of model steps is the spine"

    grow!(@agent_loop, parallel(model("m3"), model("m4")), tool("t"))
    assert_equal ["final", ["t"], []], boundary,
      "an envelope after a fan of model steps keeps the round, never a member"
    assert_equal %w[branch branch], %w[m3 m4].map { |key| node(key).continuation_source }

    grow!(@agent_loop, model("report", "results" => %w[check-1 c p1 m3]))
    assert_equal %w[final], node("report").input_from_node_keys
    assert_equal %w[check-1 c p1 m3], node("report").result_from_node_keys,
      "a later envelope names rows of earlier ones by key"
  end

  # THE EXACT CHECK: an envelope reads the spine iff some payload's input_from names it, so a model
  # continuing a round still talking is refused, and a fresh group beside a tool — which reads nothing
  # of that round — hangs below it like an ask or a tool.
  test "tip_live: refused when a payload's input_from names the live spine, accepted for a fresh group beside a tool" do
    assert_equal "queued", node("seed").status
    refused = grow(@agent_loop, model("next"))
    assert_equal :tip_live, refused.outcome
    assert_not @agent_loop.agent_loop_nodes.exists?(node_key: "next")

    hung = grow!(@agent_loop, ask("check-1"))
    assert_equal ["seed"], node("check-1").sources.map(&:node_key), "--until's first check waits below r1"
    assert_equal "check-1", deliverable_key
    assert_equal ["check-1"], hung.receipt["steps"]
    assert_predicate grow(@agent_loop, tool("probe")), :applied?

    fresh = grow(@agent_loop, parallel(model("m1"), model("m2")), tool("after"))
    assert_predicate fresh, :applied?, "#{fresh.outcome}: #{fresh.errors.inspect}"
    assert_nil node("m1").input_from_node_keys, "a member reads nothing of the live round"
    assert_equal "queued", node("seed").status

    settle!("seed")
    park!("check-1")
    %w[probe m1 m2 after].each { |key| settle!(key) }
    assert_predicate grow(@agent_loop, model("work-2", "results" => %w[check-1 probe]), ask("check-2"),
      resolves: [{ "task" => "check-1", "content" => "yes" }]), :applied?
    assert_equal %w[seed], node("work-2").input_from_node_keys, "the round continues the spine"
    assert_equal %w[check-1 probe], node("work-2").result_from_node_keys, "and reads what it names"
  end

  test "tip_unresolved: an append past a pending or skipped tip is refused until adjudicated" do
    settle!("seed", status: "failed")
    assert_equal :tip_unresolved, grow(@agent_loop, model("repair")).outcome,
      "a halt failure awaits retry or abandon; appending would never release"

    node("seed").update_columns(failure_resolution: "abandoned")
    repaired = grow!(@agent_loop, model("repair"))
    assert_equal ["repair"], repaired.receipt["accepted_task_keys"]
    assert_equal 0, node("repair").remaining_dependencies, "the resolved arm of the one formula"

    skipped = seed(model("gate", "on_failure" => "propagate"))
    skipped.agent_loop_nodes.find_by!(node_key: "gate").update_columns(status: "failed", completed_at: Time.current)
    assert_equal :tip_unresolved, grow(skipped, tool("t")).outcome,
      "a propagate-skipped tip would bear a task born skipped"
  end

  test "an absorbed failure satisfies the tip and the append proceeds" do
    AgentLoopNode.where(id: node("seed").id).update_all(on_failure: "absorb")
    settle!("seed", status: "failed")

    grow!(@agent_loop, model("next"))

    assert_equal "queued", node("next").status
    assert_equal 0, node("next").remaining_dependencies
  end

  test "a race settles in the release walk: the first success wins and the losers are canceled" do
    settle!("seed")
    grow!(@agent_loop, parallel(tool("a"), tool("b"), until: "any", key: "race"), model("after"))

    assert_equal "queued", node("race").status, "members are batch-new, so no race is ever born settled"
    assert_equal 1, node("race").remaining_dependencies
    settle!("a")
    AgentLoops::Release.settled(node("a"))

    assert_equal "completed", node("race").status
    assert_equal({ "joined" => "any", "outcomes" => { "a" => "completed", "b" => "waiting" } },
      node("race").output_summary, "the outcomes are read as the race settles, in the trace's words")
    assert_equal "canceled", node("b").status, "a public race cancels its losers by default"
    assert_equal 0, node("after").remaining_dependencies
  end

  test "a race starves when every member settled without a success" do
    settle!("seed")
    grow!(@agent_loop, parallel(tool("a"), tool("b"), until: "any", key: "race", on_failure: "absorb"), model("after"))

    %w[a b].each do |key|
      AgentLoopNode.where(id: node(key).id).update_all(on_failure: "absorb")
      settle!(key, status: "failed")
      AgentLoops::Release.settled(node(key))
    end

    race = node("race")
    assert_equal "failed", race.status
    assert_equal "join_starved", race.output_summary["join_failure"]
    assert_nil race.failure_resolution
    assert_equal :resolved, AgentLoops::Graph.settlement_of(race),
      "the group's policy is the barrier row's: absorb resolves by policy"
    assert_equal 0, node("after").remaining_dependencies, "and the follower runs, reading that nothing won"
  end

  test "init equals recount: replaying settlements over the formula reproduces every countdown" do
    settle!("seed")
    grow!(@agent_loop, parallel(tool("a"), tool("b"), until: 1, key: "j"), model("c"))

    @agent_loop.agent_loop_nodes.find_each do |row|
      sources = row.incoming_edges.map(&:from_node)
      settlements = sources.map { |s| AgentLoops::Graph.settlement_of(s) }
      expected = AgentLoops::Graph.initial_countdown(
        row.join_mode, row.quorum_k, settlements
      )
      assert_equal expected, row.remaining_dependencies,
        "#{row.node_key}: the stored countdown IS the formula's answer"
    end
  end

  test "the receipt mirrors the request tree, names the barrier and the answer, and carries the tokens" do
    settle!("seed")
    result = grow!(@agent_loop, parallel(tool("tests"), [tool("lint"), model("summary")], until: "any"),
      ask("review"), model("final"))

    assert_equal %w[tests lint summary s2-parallel-1 review final], result.receipt["accepted_task_keys"]
    assert_equal [{ "parallel" => ["tests", %w[lint summary]], "key" => "s2-parallel-1" }, "review", "final"],
      result.receipt["steps"]
    assert_equal "final", result.receipt["deliverable_task_key"]
    assert_equal 2, result.receipt["revision"]
    assert_equal node("review").resolution_token, result.receipt["resolution_tokens"].fetch("review")
    assert_equal %w[review], node("final").sources.map(&:node_key)
    assert_equal %w[seed], node("final").input_from_node_keys,
      "the follower continues the spine and reads nothing by position"
  end

  # The receipt is the plan a progress reader renders, so a keyless authored envelope leaves one
  # too, under a key nobody holds.
  test "every authored envelope leaves its receipt, a keyless one under a minted key" do
    settle!("seed")
    grow!(@agent_loop, ask("check"))
    AgentLoops::WakeContinuation.plant(agent_loop: @agent_loop, source: node("seed"))

    receipts = @agent_loop.agent_loop_append_receipts.order(:id).to_a
    assert_equal [["seed"], ["check"]], receipts.map { |receipt| receipt.response_body["steps"] },
      "the seed and the append are plans; the kernel's plant is not"
    keys = receipts.map(&:idempotency_key)
    assert_equal [36, 36], keys.map(&:bytesize), "minted keys fit the receipt's column"
    assert_equal 2, keys.uniq.length, "one key per envelope, held by nobody"
  end

  test "an envelope of resolves alone settles the await and appends nothing" do
    settle!("seed")
    grow!(@agent_loop, ask("gate"))
    park!("gate")

    assert_equal "steps_required", grow(@agent_loop).errors.sole["code"]

    result = grow!(@agent_loop, resolves: [{ "task" => "gate", "content" => "yes" }])
    assert_equal [], result.receipt["accepted_task_keys"]
    assert_equal [], result.receipt["steps"]
    assert_equal "completed", node("gate").status
    assert_equal "gate", deliverable_key, "an empty envelope moves nothing"
  end

  test "the receipt replays under the lock and a different envelope conflicts" do
    settle!("seed")
    first = grow(@agent_loop, model("r1"), idempotency_key: "key-1")
    assert_predicate first, :applied?
    assert_equal ["r1"], first.receipt["accepted_task_keys"]

    replay = grow(@agent_loop, model("r1"), idempotency_key: "key-1")
    assert_predicate replay, :replayed?
    assert_equal first.receipt, replay.receipt
    assert_equal 1, @agent_loop.agent_loop_nodes.where(node_key: "r1").count

    mismatch = grow(@agent_loop, model("r2"), idempotency_key: "key-1")
    assert_equal :idempotency_envelope_mismatch, mismatch.outcome
    assert_not @agent_loop.agent_loop_nodes.exists?(node_key: "r2")
  end

  test "reusing an expired append key leaves other expired receipts for the collector" do
    grow!(@agent_loop, ask("first"), idempotency_key: "reuse")
    grow!(@agent_loop, ask("other"), idempotency_key: "other")
    receipts = @agent_loop.agent_loop_append_receipts
    expired = receipts.find_by!(idempotency_key: "reuse")
    retained = receipts.where.not(id: expired.id).pluck(:id)
    receipts.update_all(created_at: 2.days.ago)

    accepted = grow!(@agent_loop, tool("next"), idempotency_key: "reuse")

    assert_equal ["next"], accepted.receipt.fetch("accepted_task_keys")
    assert_not AgentLoopAppendReceipt.exists?(expired.id)
    assert_equal retained.sort, receipts.where(id: retained).order(:id).pluck(:id),
      "one append releases only its own expired reservation under the loop lock"
    assert_equal accepted.receipt, receipts.find_by!(idempotency_key: "reuse").response_body
  end

  test "the revision CAS refuses stale writers and nothing lands" do
    settle!("seed")
    stale = grow(@agent_loop, model("late"), expected_revision: 99)

    assert_equal :stale_revision, stale.outcome
    assert_not @agent_loop.agent_loop_nodes.exists?(node_key: "late")

    fresh = grow(@agent_loop, model("late"), expected_revision: @agent_loop.reload.revision)
    assert_predicate fresh, :applied?
    assert_equal 2, fresh.receipt["revision"]
  end

  test "a persisted duplicate key refuses with its name, and a terminal loop refuses growth" do
    settle!("seed")
    assert_equal :duplicate_task_key, grow(@agent_loop, model("seed")).outcome

    @agent_loop.update!(status: "completed")
    assert_equal :agent_loop_not_appendable, grow(@agent_loop, model("more")).outcome
  end

  test "a retried create replays the standing loop instead of minting a twin" do
    first = create_loop(model("only"), idempotency_key: "create-1")
    assert_predicate first, :created?

    replay = create_loop(model("only"), idempotency_key: "create-1")
    assert_predicate replay, :replayed?
    assert_equal first.agent_loop.id, replay.agent_loop.id,
      "the retry finds the loop it could not name"
    assert_equal 1, AgentLoop.where(workspace_id: @workspace.id)
      .joins(:agent_loop_nodes).where(agent_loop_nodes: { node_key: "only" }).count

    mismatch = create_loop(model("other"), idempotency_key: "create-1")
    assert_equal :idempotency_envelope_mismatch, mismatch.outcome
  end

  test "the door refuses an edge word by name and a seed of only background steps" do
    refused = grow(@agent_loop, model("m", "depends_on" => ["seed"]))
    assert_equal({ "code" => "edge_authoring_refused", "path" => "steps[0].model.depends_on" }, refused.errors.sole)

    assert_equal "seed_needs_a_tip", create_loop(detached(model("bg"))).errors.sole["code"]
    assert_equal :steps_required, create_loop.outcome
  end

  # A TOOL STEP'S INPUT IS BOUNDED WHERE THE ROW IS: 64 KiB, the `envelope_bound` its `tool_input`
  # column is validated against. The batch's 1 MB check let a single oversized step through to the
  # row's `create!`, which raised — a generic `record_invalid` at the HTTP door, and on the kernel's
  # own appends a raise inside the converger. The compiler now refuses it positionally, like every
  # other bad step, and writes nothing.
  test "a tool step over the tool-input bound is refused positionally as tool_input_too_large" do
    refused = grow(@agent_loop, tool("big", "shell", "input" => { "command" => "x" * 100_000 }))

    assert_equal :invalid_steps, refused.outcome
    assert_equal "tool_input_too_large", refused.errors.sole["code"], refused.errors.inspect
    assert_match(/\Asteps\[0\]\..*input\z/, refused.errors.sole["path"])
    assert_nil node_or_nil("big"), "a refused envelope writes nothing"

    fits = grow(@agent_loop, tool("fits", "shell", "input" => { "command" => "x" * 60_000 }))
    assert_predicate fits, :applied?, "#{fits.outcome}: #{fits.errors.inspect}"
  end

  # A kernel step's pairing key is written to a string(128) column. The normalizer bounds it upstream;
  # the compiler still refuses one past the column positionally, because a refusal is an answer the
  # kernel's caller can report, and a raise at the row's `create!` is not.
  test "a kernel tool step whose tool_call_id the row cannot store is refused positionally" do
    limit = Nexus::ModelToolCalls::MAX_ID_LENGTH
    ["c" * (limit + 1), "c\u0000d"].each do |id|
      refused = Append.call(Append::Command.kernel(agent_loop: @agent_loop, origin: "kernel", tip: Tip.seed("branch"),
        steps: [Step::Tool.new(key: "long", name: "x", tool_call_id: id)]))

      assert_equal :invalid_steps, refused.outcome, id.inspect
      assert_equal [{ "code" => "invalid_tool_call_id", "path" => "steps[0].tool_call_id" }], refused.errors
      assert_nil node_or_nil("long"), "a refused envelope writes nothing"
    end

    kernel!([Step::Tool.new(key: "fits", name: "x", tool_call_id: "c" * limit)], Tip.seed("branch"), origin: "kernel")
    assert_equal "c" * limit, node("fits").tool_call_id
  end

  # ONE rule, ONE site: a delegated compaction needs an agent address to reach, and only a loop with
  # a declaring profile has one. The compiler stays loop-blind; this door holds the loop, so it
  # answers positionally through the existing `invalid_steps` arm for the seed and for growth alike.
  test "delegate_requires_agent_profile: a delegate on a Human's loop is refused positionally, an agent's is accepted" do
    delegate = { "mode" => "delegate", "tool_name" => "my_compactor" }

    refused = create_loop(model("r1"), model("r2", "compaction" => delegate))
    assert_equal :invalid_steps, refused.outcome
    assert_equal [{ "code" => "delegate_requires_agent_profile", "path" => "steps[1].compaction" }], refused.errors

    grown = grow(@agent_loop, parallel(model("a"), model("b", "compaction" => delegate)), model("after"))
    assert_equal :invalid_steps, grown.outcome
    assert_equal "steps[0].parallel[1].compaction", grown.errors.sole["path"], grown.errors.inspect
    assert_nil node_or_nil("a"), "a refused envelope writes nothing"

    accepted = create_loop(model("r1", "compaction" => delegate), creating_user: users(:agent))
    assert_predicate accepted, :created?, accepted.errors.inspect
    kernel = create_loop(model("r1", "compaction" => { "mode" => "kernel" }))
    assert_predicate kernel, :created?, "the kernel's own mode needs no address"
  end

  def node_or_nil(key) = @agent_loop.agent_loop_nodes.find_by(node_key: key)

  # THE PERSISTED FACT BEHIND "THIS ROW IS AN ARM OF THAT RACE": written at create from the compiled
  # payload, and inherited by what an arm's row expands into when the compile placed it outside any race.
  test "a race's arm rows carry its barrier, and an expansion inside an arm inherits it" do
    settle!("seed")
    grow!(@agent_loop, parallel([tool("t1"), model("m1")], [tool("t2"), model("m2")], until: "any", key: "race"),
      model("after", "results" => ["race"]))
    race = node("race")
    assert_equal [race.id] * 4, %w[t1 m1 t2 m2].map { |key| node(key).barrier_node_id }
    assert_nil race.barrier_node_id
    assert_nil node("after").barrier_node_id

    m1 = node("m1")
    kernel!([Step::Parallel.new(members: [Step::Tool.new(key: "m1t0", name: "x", tool_call_id: "c")]),
             Step.inheriting(m1, key: "m1-next")],
      kernel_tip(m1, [m1], [], "branch"), expansion_parent: m1, replaces: "m1")
    assert_equal [race.id, race.id], %w[m1t0 m1-next].map { |key| node(key).barrier_node_id },
      "a round's fan and continuation inside an arm stay the arm's"

    kernel!([Step::Tool.new(key: "planted", name: "x")], Tip.seed("branch"), origin: "kernel")
    assert_nil node("planted").barrier_node_id, "a row outside every race carries none"
  end

  # THE REPLACES ARM ROUTES BY KIND: an await carries no provider pairing, so nothing grows the
  # replacement's cursor; the head that held the composed call as an unread tip reads the replacement's
  # final waits instead — here the await the person answers.
  test "a composed ask under wait: true reaches the head as its answer" do
    seed = node("seed")
    settle!("seed")
    kernel!([Step::Parallel.new(members: [Step::Tool.new(key: "r1t0", name: "compose", tool_call_id: "c")]),
             Step.inheriting(seed, key: "r1")], kernel_tip(seed, [seed], [], "round"))
    call = node("r1t0")
    kernel!([Step::Tool.new(key: "r1t0-tool-1", name: "ask", input: { "prompt" => "Ship it?" })],
      kernel_tip(nil, [call], [], "branch"), expansion_parent: call, head: "r1")
    assert_equal %w[seed r1t0 r1t0-tool-1], node("r1").input_from_node_keys, "the unread tip reaches the waited head"

    composed = node("r1t0-tool-1")
    kernel!([Step::Ask.new(key: "r1t0-tool-1-ask-1", prompt: "Ship it?")], kernel_tip(nil, [composed], [], "branch"),
      origin: "kernel", expansion_parent: composed, replaces: "r1t0-tool-1")

    assert_equal %w[seed r1t0 r1t0-tool-1-ask-1], node("r1").input_from_node_keys,
      "the head reads the await in the composed call's place"
    assert_includes node("r1").sources.map(&:node_key), "r1t0-tool-1-ask-1", "and waits for the answer"
  end

  # A STAGE'S RESULT BOUNDARY: its manifest is the row the expansion replaced, and its insides stay
  # behind the boundary, so a detached stage comes back as its final leaf alone.
  test "a detached expanded stage delivers its final leaf, never its manifest" do
    settle!("seed")
    kernel!([Step::Script.new(key: "s", script: "return null")], Tip.seed("branch").with(detached: true))
    stage = node("s")
    stage.update_columns(status: "running", started_at: Time.current)
    kernel!([Step::Tool.new(key: "s-read", name: "x"),
             Step::Script.new(key: "s-leaf", script: "return results[0].output", results: ["s-read"])],
      AgentLoops::KernelTool.branch_tip(stage), expansion_parent: stage, replaces: "s")
    settle!("s", output_summary: { "resolved" => true })
    settle!("s-read")
    settle!("s-leaf")

    assert_equal %w[s-leaf], AgentLoops::WakeContinuation.undelivered(@agent_loop.reload).map(&:node_key)
  end

  test "a detached-only envelope splices nothing: the continuation runs at once" do
    seed = node("seed")
    kernel!([Step::Parallel.new(members: [Step::Tool.new(key: "r1t0", name: "compose", tool_call_id: "c")]),
             Step.inheriting(seed, key: "r1")], kernel_tip(seed, [seed], [], "round"))
    call = node("r1t0")

    kernel!([Step::Model.new(key: "r1t0-bg", model: MOCK_MODEL, prompt: "later", detached: true)],
      kernel_tip(nil, [call], [], "branch"), head: "r1")

    assert_equal ["r1t0"], node("r1").sources.map(&:node_key), "nothing new to wait on"
    assert_equal %w[seed r1t0], node("r1").input_from_node_keys, "nothing new to read"
    assert node("r1t0-bg").detached?
    assert_equal ["r1t0"], node("r1t0-bg").sources.map(&:node_key), "the branch hangs off the call"
  end

  # Inside a detached branch every row carries the branch's word, so the waited head — the branch's
  # own continuation — reads what its envelope placed, as it would on the main line.
  test "a waited head inside a detached branch reads its envelope's rows" do
    kernel!([Step::Model.new(key: "bg", model: MOCK_MODEL, prompt: "later", detached: true)], Tip.seed("branch"))
    branch = node("bg")
    settle!("bg")
    kernel!([Step::Parallel.new(members: [Step::Tool.new(key: "bgt0", name: "spawn", tool_call_id: "c")]),
             Step.inheriting(branch, key: "bg-next")], kernel_tip(branch, [branch], [], "branch", true))
    call = node("bgt0")
    kernel!([Step::Ask.new(key: "bgt0-ask", prompt: "child", on_failure: "absorb")],
      kernel_tip(nil, [call], [], "branch", true), holder: :kernel, expansion_parent: call, head: "bg-next")

    assert node("bgt0-ask").detached?
    assert_equal %w[bg bgt0 bgt0-ask], node("bg-next").input_from_node_keys
  end
end
