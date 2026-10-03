require "test_helper"
require_relative "../../../test_helpers/compaction_test_helper"

# Mid-turn repairs use the loop scheduler and resume the queued round from its summary.
class Conversations::Compaction::RoundRepairTest < ActiveJob::TestCase
  include CompactionTestHelper

  # ════════════════════════════════════════════════════════════════════
  # THE MID-TURN HOST: the round's backing loop
  # ════════════════════════════════════════════════════════════════════

  test "a round that will not fit is repaired instead of failed" do
    agent_loop = loop_with_history
    schedule!(agent_loop)

    round2 = node(agent_loop, "round2")
    assert_equal "queued", round2.status, "it waits for its repair, it does not die"
    assert_equal "k1", round2.compaction["summary_source"]
    summarizer = node(agent_loop, "k1")
    assert_equal "model_task", summarizer.task_kind
    assert_equal 1, round2.remaining_dependencies
    assert_includes summarizer.content_bodies.find_by(role: "input").effective_text,
      "Mock: here is what I found",
      "the summarizer reads the history it is replacing"
    assert_nil summarizer.tool_definitions, "it has one job and nothing to call"
    assert_equal "branch", summarizer.continuation_source, "a summarizer is not the conversation"
    assert_equal Conversations::Compaction::Summarizer::INSTRUCTIONS, summarizer.system_instructions
    assert_includes summarizer.system_instructions, "WHAT TO RE-READ",
      "the summariser is asked for pointers"
    refute_includes summarizer.system_instructions, "CRITICAL CONTEXT",
      "the paragraph that invited fifty-two fabricated first lines is gone"
    refute_includes summarizer.system_instructions, "numbers and error messages verbatim"
  end

  # The summarizer is a branch, so every reader of the spine sees one:
  # the wake stays blocked by the queued repaired round, the tail is the
  # round before it, and the steer boundary never drains into a summary.
  test "the spine while the repair runs: live through the repaired round, its tail never the summarizer" do
    agent_loop = loop_with_history
    schedule!(agent_loop)
    summarizer = node(agent_loop, "k1")
    assert_equal "running", summarizer.status

    assert_predicate agent_loop, :spine_live?, "the repaired round is queued on the spine"
    assert_equal "round2", agent_loop.spine_tail.node_key, "the chain's tail is the repaired round, never k1"
    assert_empty AgentLoops::Steers::ConsumeAtCheckpoint.for(agent_loop: agent_loop, node: summarizer).peek,
      "a summarizer reads history, never a person's words"
  end

  # THE REPAIR IS ONLY A REPAIR IF IT STARTS, and this is the assertion
  # that says so. The summarizer is born ready — nothing depends on it —
  # but `ready_nodes` is computed ONCE before the drain, so a node
  # appended mid-pass is invisible to it. The arm splices it into the
  # worklist the pass is already walking; without that it waits for the
  # once-a-minute sweep floor, and every compaction costs the round it
  # repairs up to a minute of dead time on the one path the code went out
  # of its way to optimise.
  #
  # IT MUST BE ONE PASS. The other tests reach the wall through `run!`,
  # whose trailing `schedule!` IS the arming pass — so their next
  # `schedule!` picks the summarizer up through `ready_nodes` and the
  # splice could be dead without a single test noticing. It was: `Arm`
  # answered `true`, and `where(node_key: true)` type-casts to
  # `node_key = 't'`.
  # A DELEGATED REPAIR RIDES A tool_input, WHICH IS AN EIGHTH THE ROOM a
  # model prompt has. Handing it prompt-sized material raised
  # RecordInvalid out of an Append that rescues only its own Refused, so
  # the exception escaped the arm, escaped ScheduleReady, and rolled back
  # the ENTIRE scheduling pass — every loop in it, once a minute,
  # forever.
  test "a delegated repair fits the room a tool input actually has" do
    # A delegate reaches the loop's declaring agent: the loop is the agent's, and the agent's
    # address announces the tool it names.
    announce_tools!(@agent, %w[summarize])
    agent_loop = loop_at_the_wall(
      compaction: { "mode" => "delegate", "tool_name" => "summarize" }, creating_user: @agent
    )

    # THE MATERIAL IS FORCED PAST THE ENVELOPE, because no fixture can
    # reach it honestly: a round whose prompt is big enough to serialize
    # past 64 KiB refuses at its own window gate long before it can
    # settle and become history. `Serialize` is bounded for a model
    # PROMPT — half a megabyte — and this is the arm's job to notice.
    #
    # IT IS TOOL POINTERS, not a run of one letter: the bound counts
    # `JSON.generate` bytes, so a rendering whose own quotes and newlines
    # escape is the only fixture that can fail here. A run of "o" expands
    # by 0.05% and fits any budget; this one expands by 5.4%.
    oversized = [escaping_transcript(600_000), escaping_transcript(40_000)]
    refute Nexus::SizeBounds.json_within?(:envelope_bound,
      { "history" => oversized.first.byteslice(0, 23_488), "retained_tail" => oversized.last }),
      "the fixture must exhaust a raw-byte budget, or it cannot exhibit the defect"
    Conversations::Compaction::Serialize.stub(:call, ->(_entries) { oversized }) do
      schedule!(agent_loop)
    end

    summarizer = node(agent_loop, "k1")
    assert_equal "tool_task", summarizer.task_kind
    assert Nexus::SizeBounds.json_within?(:envelope_bound, summarizer.tool_input),
      "an oversized tool_input raised RecordInvalid past an Append that " \
      "rescues only Refused, rolling back the whole scheduling pass"
    assert_equal 40_000, summarizer.tool_input.fetch("retained_tail").bytesize,
      "the tail is not what yields — it is the part kept specific"
    history = summarizer.tool_input.fetch("history")
    assert_operator history.bytesize, :<, 600_000
    assert history.end_with?(oversized.first[-1]), "the clamp drops the OLDEST material"
  end

  # AND IT SAYS SO. Compaction is the one repair a watcher cannot infer:
  # the round pauses, a task nobody authored appears, and the next round
  # answers from a summary instead of the history it had. Narrating
  # nothing left that reaching a client as an unexplained new task.
  test "the loop plane narrates the compaction it performed" do
    announce_tools!(@agent, %w[sum])
    agent_loop = loop_with_history(compaction: { "mode" => "delegate", "tool_name" => "sum" },
      creating_user: @agent)
    schedule!(agent_loop)

    item = agent_loop.conversation_event_items.find_by!(item_type: "context_compacted")

    assert_equal "round2", item.payload["task_key"]
    assert_equal "k1", item.payload["summary_task_key"]
    assert_equal "delegate", item.payload["mode"]
    assert_equal "wall", item.payload["trigger"], "why it fired, beside what the arm chose"
    assert_equal agent_loop.public_id, item.payload["agent_loop_public_id"]
    refute item.payload.key?("turn_public_id"), "a standalone loop backs no turn"
    assert_empty item.payload.keys - %w[agent_loop_public_id task_key summary_task_key mode trigger],
      "task-grained: this vocabulary names tasks by key and never a node " \
      "id, a countdown, or a generation"
  end

  test "the kernel mode narrates as kernel even when nothing was authored" do
    agent_loop = loop_with_history
    schedule!(agent_loop)

    item = agent_loop.conversation_event_items.find_by!(item_type: "context_compacted")
    assert_equal "kernel", item.payload["mode"], "the default is a fact, not a nil"
  end

  # A TRANSIENT FAULT ON THE REPAIR WAS A PERMANENT VERDICT. The
  # summarizer is authored `on_failure: absorb` so a failed repair cannot
  # poison the round it was repairing — but absorb stamps a
  # `failure_resolution`, and every retry door in the kernel refuses a
  # node carrying one. With the default budget of zero, a 503 on the
  # summarizer resolved the repair away, the round ran again, hit the
  # same wall, and died on size for a reason that had nothing to do with
  # size. A round is repaired at most once, so nothing behind this
  # catches it.
  test "the summarizer retries a transient fault instead of dying resolved" do
    agent_loop = loop_with_history
    schedule!(agent_loop)
    summarizer = node(agent_loop, "k1")
    assert_equal Conversations::Compaction::Summarizer::RETRIES, summarizer.retry_budget

    # A PROVIDER OUTAGE LONGER THAN ONE INVOCATION. Transient faults are
    # retried below the node, at the attempt layer, so the honest test is
    # the one that spends that budget: only then does the node's own
    # policy decide, and only there was the default of zero fatal.
    3.times do
      apply_via(step_attempt(agent_loop, "k1"),
        json_response(503, { "error" => { "message" => "overloaded" } }))
      # The cooldown is measured against the DATABASE clock, which
      # `travel` does not move; expiring it is what waiting would do.
      ModelInvocation.where(id: summarizer.selected_model_invocation_id)
        .update_all(next_admission_at: nil)
    end
    AgentLoops::ConvergeTerminalSteps.call

    summarizer.reload
    assert_equal "queued", summarizer.status, "it runs again, with a fresh invocation"
    assert_equal 1, summarizer.auto_retries_used
    assert_nil summarizer.failure_resolution,
      "a resolution here is the door closing — no retry path in the kernel " \
      "reopens a node that carries one, `Tasks::Retry` included"
    assert_equal "k1", node(agent_loop, "round2").compaction["summary_source"],
      "the round is still waiting for the repair, not failed on size"
  end

  # THE THIRD ARM. The other two catch a round before it is sent; neither
  # fires on a lane with no token counter, which is four of them including
  # this repo's own live lane. There the PROVIDER's refusal is the only
  # signal — and until this it was also the most expensive one, because
  # the retry re-sent the identical oversized request until the budget was
  # spent and every attempt was billed.
  test "a provider that refuses for length arms a repair instead of retrying" do
    # SMALL ON PURPOSE. This arm only ever fires where the other two
    # cannot, so the fixture has to pass the pre-send gate and be refused
    # on the far side — a round the composer already caught would never
    # reach a provider at all.
    # WITH A RETRY BUDGET, because that is the behaviour being displaced.
    # Retrying is what this round would otherwise do with a refusal that
    # says the request will never fit: re-send it, byte for byte, and be
    # billed for each attempt until the budget is gone.
    agent_loop = loop_at_the_wall(bulk: "start the work", retry_budget: 2)
    schedule!(agent_loop)
    round2 = node(agent_loop, "round2")
    assert_equal 2, round2.retry_budget
    retries_before = round2.auto_retries_used

    overflow!(agent_loop, "round2")

    round2.reload
    assert_equal "queued", round2.status, "requeued for the repair, not failed"
    assert_equal retries_before, round2.auto_retries_used,
      "a repair is not a failed attempt — charging the budget would spend the " \
      "retries that exist for transient faults on a problem retrying cannot solve"
    assert_equal "k1", round2.compaction["summary_source"]
    assert_equal "model_task", node(agent_loop, "k1").task_kind
    assert_equal "overflow",
      agent_loop.conversation_event_items.find_by!(item_type: "context_compacted").payload["trigger"],
      "the provider's refusal is its own kind: nothing pre-send saw this wall"
  end

  # A repair is armed at most once per wall on this arm too — the mark is
  # the same fence. A second length refusal after a summary means the
  # summary itself does not fit, and the round dies honestly.
  test "a second length refusal after a repair fails rather than arming again" do
    agent_loop = loop_at_the_wall(bulk: "start the work")
    schedule!(agent_loop)
    overflow!(agent_loop, "round2")
    # The converge path arms; it does not drain. The summarizer waits for
    # the next scheduling pass exactly as any other queued node does.
    schedule!(agent_loop)
    run!(agent_loop, "k1", "THE SUMMARY")

    overflow!(agent_loop, "round2")

    assert_equal "failed", node(agent_loop, "round2").reload.status
    assert_equal 1, agent_loop.agent_loop_nodes.where(node_key: "k1").count,
      "compacting a compaction is a loop, not a repair"
  end

  # A dying loop repairs nothing: arming a round no live consumer waits
  # for is the exact spend the abandonment guard exists to stop.
  test "a canceling loop settles rather than repairing" do
    agent_loop = loop_at_the_wall(bulk: "start the work")
    schedule!(agent_loop)
    AgentLoop.where(id: agent_loop.id).update_all(status: "canceling")

    overflow!(agent_loop, "round2")

    assert_equal "canceled", node(agent_loop, "round2").reload.status
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "k1")
  end

  test "the pass that arms the repair also starts it" do
    agent_loop = loop_at_the_wall

    schedule!(agent_loop)

    summarizer = node(agent_loop, "k1")
    assert_equal "running", summarizer.status,
      "armed and left queued means the round waits on a sweep floor"
    assert_not_nil summarizer.selected_model_invocation_id
  end

  test "the repaired round reads the summary and nothing it replaced" do
    agent_loop = loop_with_history
    schedule!(agent_loop)
    run!(agent_loop, "k1", "GOAL: finish the work. DONE: found the thing.")

    request = ModelInvocation.find(node(agent_loop, "round2").selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
    texts = request.map { |p| [p["role"], p.dig("parts", 0, "text")] }

    assert_equal [
      ["user", "#{Conversations::Compaction::REREAD_RULE}\n\nMock: GOAL: finish the work. DONE: found the thing."],
      ["user", "keep going #{BULK}"],
    ], texts,
      "a deliberate chain break: the summary is MATERIAL under the kernel's re-read frame, " \
        "never a spine - replaying the summarizer's own request would put the history back"
  end

  # `off` is the predecessor's entire posture, and a client driving its
  # own loop needs the typed refusal rather than a repair it did not ask
  # for.
  test "off keeps the typed refusal" do
    agent_loop = loop_with_history(compaction: { "mode" => "off" })
    schedule!(agent_loop)

    round2 = node(agent_loop, "round2")
    assert_equal "failed", round2.status
    assert_equal "estimated_input_exceeds_model_limit", round2.error_key
  end

  # THE TWO WALLS ARE ONE DECISION. The window is what binds on a lane
  # that can count exactly; the composer's byte bound is what binds on a
  # lane that cannot. Both mean the same thing — this will not go — and
  # both arm the same repair, so the two names stay pinned together here
  # rather than drifting apart in two files.
  test "both size refusals arm the repair" do
    assert_equal [AgentLoops::InputComposition::CONTEXT_OVERFLOW,
                  :estimated_input_exceeds_model_limit].sort,
      AgentLoops::ScheduleReady::SIZE_REFUSALS.sort
  end

  # A round with nothing behind it cannot be repaired by summarizing a
  # history it does not have — one oversized prompt is just too big.
  test "a first round with no history fails honestly" do
    agent_loop = create_loop!(model("solo", "prompt" => BULK * 3))
    solo = node(agent_loop, "solo")
    assert_equal "failed", solo.status
    assert_equal "estimated_input_exceeds_model_limit", solo.error_key
    assert_nil solo.compaction
  end

  # The owner's second requirement: the agent may supply its own
  # implementation. It settles into the same slot, and the composer
  # cannot tell the two apart.
  test "delegate arms the agent's own tool instead" do
    announce_tools!(@agent, %w[my_compactor])
    agent_loop = loop_with_history(
      compaction: { "mode" => "delegate", "tool_name" => "my_compactor" }, creating_user: @agent
    )
    schedule!(agent_loop)

    summarizer = node(agent_loop, "k1")
    assert_equal "tool_task", summarizer.task_kind
    assert_equal "dispatched", summarizer.status, "addressed to the agent's own announcing address"
    assert_equal "my_compactor", summarizer.tool_name
    assert_includes summarizer.tool_input["history"], "here is what I found"
    assert_equal "round2", summarizer.tool_input["task"]
    # A standalone loop is its own host and names itself.
    assert_equal agent_loop.public_id, summarizer.tool_input["agent_loop"]
    refute summarizer.tool_input.key?("conversation")
    refute summarizer.tool_input.key?("turn")
  end

  # Compacting a compaction is a loop, not a repair. The mark the first
  # repair left is what stops the second: if a summarized round still
  # will not fit, the honest answer is the refusal.
  test "a round is repaired at most once" do
    agent_loop = loop_with_history
    schedule!(agent_loop)
    run!(agent_loop, "k1", "a summary")
    before = agent_loop.agent_loop_nodes.count

    3.times { schedule!(agent_loop) }
    assert_equal before, agent_loop.reload.agent_loop_nodes.count,
      "no second summarizer"
    assert_equal "k1", node(agent_loop, "round2").compaction["summary_source"]

    # And the mark REALLY is the fence: standing at the wall again with
    # it in place fails rather than arming.
    assert_not Conversations::Compaction::Arm.call(
      agent_loop: agent_loop, node: node(agent_loop, "round2"),
      trigger: Conversations::Compaction::Trigger.wall(node(agent_loop, "round2"))
    )
  end
end
