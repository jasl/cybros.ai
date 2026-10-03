require "test_helper"
require_relative "../../../test_helpers/compaction_test_helper"

# Manual compaction and raw/off policies reach the existing repair on each host.
class Conversations::Compaction::RequestTest < ActiveJob::TestCase
  include CompactionTestHelper

  # ════════════════════════════════════════════════════════════════════
  # THE BETWEEN-TURN HOST: a `compaction_summary` turn behind a one-task loop
  # ════════════════════════════════════════════════════════════════════

  # COMPACT NOW, BECAUSE SOMEBODY ASKED. The kernel picking no threshold
  # was never meant to mean a CALLER could not ask either — but the size
  # wall was the only trigger on either plane, so a person who could see
  # the conversation getting expensive had no way to say so.
  test "a caller can compact on demand, and the model defaults to the conversation's own" do
    build_history!
    accept!(kind: "direct_reply", text: "what now", provider_id: "dev", model_ref: "mock-text")
    drain!
    settle_reply!("here is the answer")

    result = Conversations::Compaction::Request.call(
      Conversations::Compaction::Request::Command.new(
        conversation: @conversation, acting_user: @human
      )
    )

    assert_predicate result, :accepted?
    variant = result.value.turn.active_variant
    assert_equal "dev", variant.provider_id, "unnamed, it inherits the conversation's own model"
    assert_equal "mock-text", variant.model_ref
    assert_equal "agent_loop", variant.source, "a summary turn is backed by a one-task kernel loop"
    assert_equal "compaction_summary", result.value.turn.kind
    assert_equal "user", result.value.turn.role,
      "a summary of what a user said must never arrive as an instruction"
  end

  # THE SAME REPAIR, so the summary a caller asked for cuts the history
  # exactly as the wall's would — that is the whole reason this is a door
  # onto `Arm` and not a second implementation.
  test "a manual summary replaces the history for the next send" do
    build_history!
    accept!(kind: "direct_reply", text: "what now", provider_id: "dev", model_ref: "mock-text")
    drain!
    settle_reply!("here is the answer")

    Conversations::Compaction::Request.call(
      Conversations::Compaction::Request::Command.new(
        conversation: @conversation, acting_user: @human
      )
    )
    settle_summary!("THE COMPACTED SUMMARY")

    messages = Conversations::ContextAssembly.assemble(conversation: @conversation, principal: @human).messages
    text = messages.map { |message| message.parts.map(&:text).join(" ") }.join("\n")
    assert_includes text, "THE COMPACTED SUMMARY"
    refute_includes text, "turn0", "history begins at the summary, not before it"
  end

  test "a busy lane refuses rather than taking the active turn away" do
    build_history!
    accept!(kind: "direct_reply", text: "what now", provider_id: "dev", model_ref: "mock-text")
    drain!

    result = Conversations::Compaction::Request.call(
      Conversations::Compaction::Request::Command.new(
        conversation: @conversation, acting_user: @human
      )
    )

    assert_equal :conversation_busy, result.outcome,
      "the arm claims `active_turn`; doing that under a running reply takes " \
      "it away from an invocation that is still going to settle onto it"
  end

  test "nothing to compact refuses rather than summarizing air" do
    # No history at all: the prompt alone is what will not fit.
    accept!(kind: "direct_reply", text: SecureRandom.hex(20_000),
      provider_id: "dev", model_ref: "mock-text")
    drain!

    assert_nil summary_turn, "there was nothing to summarize"
    assert_equal "blocked", @conversation.conversation_inputs.sole.state
    assert_equal 0, AgentLoop.count
    assert_equal 0, ModelInvocation.count, "nothing was sent, nothing was billed"
  end

  # COMPACT NOW, LOOP SIDE. The kernel picking no threshold was never
  # meant to mean a CALLER could not ask either — but the size wall was
  # the only trigger, on both planes.
  test "a caller can compact a queued round on demand" do
    # SMALL, so the automatic arm has not already fired: this door exists
    # for the round that fits today and will not fit in ten rounds.
    agent_loop = loop_at_the_wall(bulk: "the work so far")

    result = compact(agent_loop, "round2")

    assert_predicate result, :accepted?
    assert_equal "k1", result.summary_task_key,
      "the answer names the summarizer, so a caller can follow the repair " \
      "it asked for without diffing the graph"
    round2 = node(agent_loop, "round2")
    assert_equal "k1", round2.compaction["summary_source"]
    assert_equal 1, round2.remaining_dependencies, "it waits for the summary"
    assert_includes node(agent_loop, "k1").content_bodies.find_by(role: "input").effective_text,
      "Mock: here is what I found", "the same repair, reading the same history"
    assert_equal "manual",
      agent_loop.conversation_event_items.find_by!(item_type: "context_compacted").payload["trigger"],
      "a person asked, and the feed says so"
  end

  # EACH REFUSAL SAYS SOMETHING DIFFERENT, which is the point of a manual
  # door: the automatic caller has one answer to all of these — fail the
  # round on size — and a person who asked is owed which one it was.
  test "the manual door names the reason it refused" do
    agent_loop = loop_at_the_wall(bulk: "the work so far")

    assert_equal :task_not_found, compact(agent_loop, "nope").outcome
    # A ROUND ALREADY ON THE WIRE CANNOT BE COMPACTED, and the reason is
    # not policy: the summary is spliced AHEAD of the round that reads
    # it, and a started round's request is already sealed. `round1` here
    # is finished, which is the same fact one step further on.
    assert_equal :task_not_queued, compact(agent_loop, "round1").outcome

    assert_predicate compact(agent_loop, "round2"), :accepted?
    assert_equal :already_compacted, compact(agent_loop, "round2").outcome,
      "compacting a compaction is a loop, not a repair"
  end

  # THE SEAM'S VETO (`AgentLoop#overridden?`): behind a person's edit the loop has been answered
  # for, and every person's verb refuses `not_adjudicable` — the manual compaction door included, or
  # a compact on a still-queued round would arm a summarizer and a ScheduleJob on a loop whose turn
  # no longer shows it (pre-audit L341, 2026-09-18).
  test "the manual door refuses a loop behind a person's edit" do
    seam = create_loop_backed_turn(conversation: @conversation, acting_user: @agent)
    other = ConversationTurnVariant.create!(account: @account, conversation_turn: seam.turn, position: 1,
      status: "completed", source: "inference")
    seam.turn.update!(active_variant: other)

    assert_equal :not_adjudicable, compact(seam.agent_loop, "any").outcome
    assert_no_enqueued_jobs only: AgentLoops::ScheduleJob
  end

  test "a round that reads nothing has nothing to compact" do
    # SEQUENCED, NOT FED: a background step waits its turn but reads no
    # history at all — the same position a first round is in. A summary
    # here would be a model call spent on nothing.
    agent_loop = create_loop!(model("round1", "prompt" => "start"), tool("t"),
      detached(model("round2", "prompt" => "keep going")))

    assert_equal "queued", node(agent_loop, "round2").status
    assert_empty node(agent_loop, "round2").input_from_node_keys.to_a
    assert_equal :nothing_to_compact, compact(agent_loop, "round2").outcome
  end

  test "a policy of off refuses rather than quietly obliging" do
    agent_loop = loop_at_the_wall(
      bulk: "the work so far", compaction: { "mode" => "off" }
    )

    assert_equal :compaction_disabled, compact(agent_loop, "round2").outcome,
      "`off` means a client is driving its own loop and wants the signal, " \
      "not a repair it did not ask for — a manual call does not override that"
  end

  # ════════════════════════════════════════════════════════════════════ THE RAW RULE: under raw the
  # kernel owns no history ════════════════════════════════════════════════════════════════════

  test "under raw the kernel mode refuses to arm and the round fails saying so; a delegate arms" do
    conversation, _turn, agent_loop = loop_backed_read!(
      body: "a small file\n", words: prose(40_000), context_mode: "raw", text: "read the index, raw"
    )
    assert_predicate agent_loop, :raw?, "the turn's mechanism rides the loop"

    schedule_loop!(agent_loop)

    r2 = loop_node(agent_loop, "r2")
    assert_equal "failed", r2.status
    assert_equal "compaction_unavailable_under_raw", r2.error_key
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "k1")
    assert_nil r2.compaction
    assert_empty conversation.conversation_event_items.where(item_type: "context_compacted")
    assert_equal :compaction_unavailable_under_raw, Conversations::Compaction::Arm.refusal_for_round(r2)

    _conversation, _turn, delegated = loop_backed_read!(
      body: "a small file\n", words: prose(40_000), context_mode: "raw", text: "read the index, raw",
      compaction_policy: { "mode" => "delegate", "tool_name" => "my_compactor" }
    )
    schedule_loop!(delegated)
    assert_equal "k1", loop_node(delegated, "r2").compaction["summary_source"], "the agent owns its own history"
    summarizer = loop_node(delegated, "k1")
    assert_equal "tool_task", summarizer.task_kind
    # THE MODEL-FACING ADDRESS OF THE TIMELINE: on a loop-backed turn the delegate is told the
    # conversation, the turn and the round — never the loop's own id, which is the seam's and not
    # the agent's.
    assert_equal(
      { "conversation" => delegated.conversation.public_id, "turn" => delegated.conversation_turn.public_id,
        "task" => "r2" },
      summarizer.tool_input.slice("conversation", "turn", "task", "agent_loop")
    )
  end

  test "a raw head between turns blocks on the raw rule instead of a summary nobody could read" do
    build_history!
    head = accept!(kind: "direct_reply", context_mode: "raw", provider_id: "dev", model_ref: "mock-text",
      text: "and now what #{SecureRandom.hex(20_000)}")

    assert_equal 0, drain!

    assert_equal "blocked", head.reload.state
    assert_equal "compaction_unavailable_under_raw", head.blocked_reason
    assert_nil summary_turn
  end

  # ════════════════════════════════════════════════════════════════════ THE MANUAL DOOR MID-TURN:
  # conv → loop ════════════════════════════════════════════════════════════════════

  # A person compacting a conversation whose reply is a running loop
  # compacts that loop's newest queued round — the one whose request is
  # not yet sealed — and hears the loop's own vocabulary.
  test "the manual door reaches a running loop-backed turn on its spine's newest queued round" do
    conversation, turn, agent_loop = loop_backed_read!(body: "a small file\n")
    r2 = loop_node(agent_loop, "r2")
    assert_equal "queued", r2.status

    result = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: conversation, acting_user: @human
    ))

    assert_predicate result, :accepted?
    assert_equal turn, result.value.turn
    assert_equal "r2", result.value.task.node_key
    assert_equal "k1", result.value.summary_task_key
    assert_equal "k1", r2.reload.compaction["summary_source"]
    assert_equal "manual", compacted_item(conversation).payload["trigger"]
    assert_equal turn.public_id, compacted_item(conversation).payload["turn_public_id"]
    assert_nil conversation.conversation_turns.find_by(kind: "compaction_summary"), "no summary turn mid-turn"

    again = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: conversation, acting_user: @human
    ))
    assert_equal :already_compacted, again.outcome, "the loop's vocabulary answers"

    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("THE SUMMARY"))
    assert_equal "running", loop_node(agent_loop, "r2").reload.status, "the round reads the summary and goes"
    sealed = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: conversation, acting_user: @human
    ))
    assert_equal :task_not_queued, sealed.outcome, "a round on the wire has a sealed request"
  end

  test "the manual door is busy only for a direct reply in flight or a running summary" do
    build_history!(turns: 2, hex: 40)
    ask_greedily!(text: "a direct reply")
    assert_equal 1, drain!
    busy = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: @conversation, acting_user: @human, model: "dev/mock-text"
    ))
    assert_equal :conversation_busy, busy.outcome, "one sealed request nothing can shrink"
    settle_reply!("done")

    first = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: @conversation, acting_user: @human, model: "dev/mock-text"
    ))
    assert_predicate first, :accepted?
    assert_equal "compaction_summary", first.value.turn.kind
    assert_nil first.value.task
    second = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: @conversation, acting_user: @human, model: "dev/mock-text"
    ))
    assert_equal :conversation_busy, second.outcome, "its own summary is running"
  end
end
