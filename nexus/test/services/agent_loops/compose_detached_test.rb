require "test_helper"
require "test_helpers/compose_test_helper"

# A DETACHED `compose`: without `wait: true` on the call the whole subgraph runs in the background —
# nothing spliced under the round's continuation — and the kernel delivers what no step of it read to
# a later round, once, whatever kind of task it is.
class AgentLoops::ComposeDetachedTest < ActiveJob::TestCase
  include InvocationHarness
  include ComposeTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  # DETACHED BY DEFAULT: the WHEN word is `wait` on the CALL. Without `wait: true` the whole
  # subgraph runs in the background — every node `detached`, nothing spliced under the continuation
  # — and the kernel delivers its tips to a later round, which is what makes "start it and keep
  # working" honest rather than a way to lose the result.
  test "a detached compose does not hold the round, and its answer arrives later" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, 'g.model({ prompt: "think it over", key: "bg" });')

    assert_equal %w[r1t0], sources_of(agent_loop, "r1"),
      "the round waits on the compose call alone, never on the subgraph"
    assert_equal %w[round1 call_c], read_by(agent_loop, "r1")
    bg = node(agent_loop, "r1t0-bg")
    assert bg.detached?
    assert_nil bg.input_from_node_keys, "a subagent starts from its brief"
    assert_equal "branch", bg.continuation_source
    assert_equal "Composed 1 task: r1t0-bg.\nLine 1 g.model(\"think it over\") starts from its prompt alone.\n" \
      "They run in the background: each result reaches you in this loop before it completes.\n" \
      "Task reference: agent_loop=\"#{agent_loop.public_id}\", task=\"r1t0\".", tool_result(agent_loop, "r1t0")

    # The branch settles while the spine is busy: nothing is delivered
    # yet, because a running round's request is already sealed.
    run!(agent_loop, "r1t0-bg", "a considered thought")
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "w1")

    # The spine finishes with nothing outstanding but the branch — and
    # the kernel wakes it rather than letting the loop end unread.
    run!(agent_loop, "r1", "done with my part")

    wake = node(agent_loop, "w1")
    assert_equal "round", wake.continuation_source, "the wake IS the conversation's next round"
    assert_equal %w[r1t0-bg], sources_of(agent_loop, "w1"), "the branch's tip is delivered"
    assert_equal %w[r1 r1t0-bg], wake.input_from_node_keys, "read beside the spine's tail"
    assert_equal agent_loop.reload.deliverable_node_id, wake.id,
      "a loop must not complete on a round that has not seen the work"
  end

  # THE TWO WORDS side by side: `wait: true` splices the subgraph under the
  # continuation as before and answers with the waited manifest; `false`
  # spells the default.
  test "the call's wait: true splices the subgraph under the continuation as before" do
    waited = loop_with_round
    compose_round!(waited, 'g.model({ prompt: "now", key: "n" });', wait: true)
    assert_equal %w[r1t0 r1t0-n], sources_of(waited, "r1")
    assert_equal %w[round1 call_c r1t0-n], read_by(waited, "r1")
    refute_predicate node(waited, "r1t0-n"), :detached?
    assert_equal "Composed 1 task: r1t0-n.\nLine 1 g.model(\"now\") starts from its prompt alone.\n" \
      "Their results reach you in the next round.\n" \
      "Task reference: agent_loop=\"#{waited.public_id}\", task=\"r1t0\".", tool_result(waited, "r1t0")

    spelled = loop_with_round
    compose_round!(spelled, 'g.model({ prompt: "later", key: "l" });', wait: false)
    assert_equal %w[r1t0], sources_of(spelled, "r1"), "wait: false is the default, spelled"
    assert_predicate node(spelled, "r1t0-l"), :detached?
  end

  test "wait that is not a boolean is refused by sentence" do
    agent_loop = loop_with_round
    compose_round!(agent_loop, 'g.model({ prompt: "p", key: "p" });', wait: "yes")
    assert node(agent_loop, "r1t0").output_summary["is_error"]
    assert_equal AgentLoops::TaskTool::Run::INVALID_WAIT, tool_result(agent_loop, "r1t0")
    assert_equal %w[r1 r1t0 round1], agent_loop.agent_loop_nodes.pluck(:node_key).sort, "nothing lowered"
  end

  # A DETACHED SUBGRAPH MAY END ON A FAN: with no continuation to splice
  # under, each tip is a receipt of its own — the wake round reads every
  # settled tip at once (a hosted loop mails one per tip). The same script
  # under `wait: true` is fine too, because the continuation follows; only
  # a headless attached envelope is refused `fan_needs_follower`.
  test "a detached compose ending on a fan is accepted and each tip is delivered" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, <<~JS)
      g.parallel([
        g.tool({ name: "read_file", input: { path: "a" }, key: "a" }),
        g.tool({ name: "read_file", input: { path: "b" }, key: "b" }),
      ]);
    JS

    assert_equal "completed", node(agent_loop, "r1t0").status
    refute node(agent_loop, "r1t0").output_summary["is_error"], tool_result(agent_loop, "r1t0")
    assert_match(/\AComposed 2 tasks: r1t0-a, r1t0-b\./, tool_result(agent_loop, "r1t0"))
    assert %w[r1t0-a r1t0-b].all? { |key| node(agent_loop, key).detached? }
    assert_equal %w[r1t0], sources_of(agent_loop, "r1")

    settle_tool!(agent_loop, "r1t0-a", "the first")
    settle_tool!(agent_loop, "r1t0-b", "the second")
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "w1"), "a running round's request is sealed"
    run!(agent_loop, "r1", "done with my part")
    wake = node(agent_loop, "w1")
    assert_equal %w[r1t0-a r1t0-b], sources_of(agent_loop, "w1"), "every tip of the fan is delivered"
    assert_equal %w[r1 r1t0-a r1t0-b], wake.input_from_node_keys
  end

  # The deliverable is the continuation's, and a detached append cannot take it: the call is neither
  # the start's spine nor its sole wait.
  test "a detached compose never moves the deliverable" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, <<~JS)
      g.tool({ name: "read_file", input: { path: "a" }, key: "a" });
      g.model({ prompt: "read it", key: "m" });
    JS
    assert_equal "r1", agent_loop.reload.deliverable_node.node_key,
      "the continuation stays the deliverable; the detached subgraph's tip never takes it"
  end

  # Level-triggered like everything else: a second pass finds the work
  # delivered by the edge it drew, and appends nothing.
  test "delivery happens once" do
    agent_loop = loop_with_round
    compose_round!(agent_loop, 'g.model({ prompt: "go", key: "bg" });')
    run!(agent_loop, "r1", "spine done")
    run!(agent_loop, "r1t0-bg", "branch done")
    before = agent_loop.agent_loop_nodes.count

    3.times { schedule!(agent_loop) }
    assert_equal before, agent_loop.reload.agent_loop_nodes.count
  end

  # A DETACHED TIP IS ANY KIND. `detach` was once compiled for model
  # tasks only, so a detached tool settled into a graph nothing waited on,
  # nothing read, and the wake could not see — its answer lost, while
  # the tool description promises the model not to poll for it.
  test "a detached tool is delivered, not lost" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, 'g.tool({ name: "read_file", input: { path: "slow.rb" }, key: "bg" });')
    assert node(agent_loop, "r1t0-bg").detached?

    run!(agent_loop, "r1", "done with my part")
    settle_tool!(agent_loop, "r1t0-bg", "the slow answer")

    assert_equal %w[r1t0-bg], sources_of(agent_loop, "w1"),
      "the settle door reaches quiescence before any scheduling pass, so " \
        "the delivery guarantee has to live there"
  end

  # A DETACHED BRANCH THAT CALLS A TOOL gains a fan and a continuation.
  # Unless those are detached too, the branch acquires a dependent and
  # drops out of the wake's frontier — losing its answer exactly when it
  # did the most work.
  test "a detached branch stays detached through its own rounds" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, 'g.model({ prompt: "dig into it", key: "bg" });')
    run!(agent_loop, "r1", "my part is done")

    apply_via(step_attempt(agent_loop, "r1t0-bg"),
      sse_success("looking", tool_calls: [
        { id: "call_x", name: "read_file", arguments: '{"path":"a"}' },
      ]))
    AgentLoops::ConvergeTerminalSteps.call
    schedule!(agent_loop)

    fan = agent_loop.agent_loop_nodes.where("node_key LIKE 'r2%'").to_a
    assert fan.any?, "the branch expanded"
    assert fan.all?(&:detached?),
      "a branch's own fan and continuation are its business, not the round's"
  end

  # The mark has one writer: a client-authored round on the loop's path
  # is `round`, so the spine's tail is never a NULL the wake cannot find.
  test "a client-authored round is the spine the wake continues from" do
    agent_loop = loop_with_round
    compose_round!(agent_loop, 'g.model({ prompt: "background", key: "bg" });')
    run!(agent_loop, "r1", "spine done")
    run!(agent_loop, "r1t0-bg", "branch done")

    wake = node(agent_loop, "w1")
    assert_equal "round", node(agent_loop, "round1").continuation_source,
      "the loop's own first round is the spine by position"
    assert_equal "round", wake.continuation_source
  end

  # Inside a detached subgraph the steps still wire to each other — a
  # model step reads what it names — while the round waits on none of
  # them: the subgraph's last step is the tip the wake delivers.
  test "a detached compose's steps still wait on each other inside it, and the round on none of them" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, <<~JS)
      const a = g.tool({ name: "read_file", input: { path: "a" }, key: "a" });
      g.model({ prompt: "read it", key: "b", results: [a] });
    JS

    assert_equal %w[r1t0], sources_of(agent_loop, "r1")
    assert_equal %w[round1 call_c], read_by(agent_loop, "r1"),
      "the round neither waits on nor reads a detached subgraph"
    assert_equal %w[r1t0-a], sources_of(agent_loop, "r1t0-b"), "b waits on a inside the subgraph"
    assert_equal %w[r1t0-a], node(agent_loop, "r1t0-b").result_from_node_keys, "and reads it by name"
    assert %w[r1t0-a r1t0-b].all? { |key| node(agent_loop, key).detached? }

    settle_tool!(agent_loop, "r1t0-a", "the file")
    run!(agent_loop, "r1t0-b", "read")
    run!(agent_loop, "r1", "done with my part")
    assert_equal %w[r1t0-b], sources_of(agent_loop, "w1"), "the subgraph's tip alone is delivered"
  end

  # A detached tip that failed would make the wake round born SKIPPED —
  # taking every sibling's good answer with it, silently. Every task a
  # model authors absorbs its own failure, and a script cannot say otherwise.
  test "a detached failure cannot poison the round that reads it" do
    agent_loop = loop_with_round
    compose_round!(agent_loop, <<~JS)
      g.model({ prompt: "one", key: "one" });
      g.model({ prompt: "two", key: "two" });
    JS
    assert_equal %w[absorb absorb], %w[one two].map { |k| node(agent_loop, "r1t0-#{k}").on_failure },
      "model-authored work absorbs - nothing in the round waits on it"

    insisting = loop_with_round
    compose_round!(insisting, 'g.model({ prompt: "one", on_failure: "propagate" });')
    assert_includes tool_result(insisting, "r1t0"),
      "on_failure is not a compose option: a step that fails reaches you as an error envelope."
  end
end
