require "test_helper"
require_relative "../../../test_helpers/compaction_test_helper"

# Between-turn repairs settle through a summary loop and preserve the timeline cut.
class Conversations::Compaction::TimelineRepairTest < ActiveJob::TestCase
  include CompactionTestHelper

  # COMPACTION MUST MAKE ASSEMBLY CHEAPER, and it did not. The cut was
  # derived by walking a FULLY LOADED timeline — every reachable turn
  # read out of the database and then discarded in Ruby — so a compacted
  # conversation paid for a summary AND for reading everything the
  # summary replaced, on the one path compaction exists to make cheaper.
  test "a compacted conversation reads fewer rows, not more" do
    30.times { |n| accept!(text: "turn#{n}") }
    drain!
    before = turns_read { Conversations::ContextAssembly.assemble(conversation: @conversation, principal: @human) }

    summarize!

    after = turns_read { Conversations::ContextAssembly.assemble(conversation: @conversation, principal: @human) }
    assert_operator after, :<, before,
      "the summary stands in for the turns before it; reading them anyway is " \
      "the cost compaction was supposed to remove"
    assert_operator after, :<=, 2,
      "what it reads is the summary and whatever follows — not the history"
  end

  # THE EVIDENCE SURVIVES THE OPTIMIZATION. `compacted` and `skipped` are
  # what a trim-planning client reads, and both used to be counted from
  # rows this walk no longer loads. Counting them in SQL has to give the
  # same answer or the saving was bought with a lie.
  test "the history evidence is unchanged by where the counting happens" do
    30.times { |n| accept!(text: "turn#{n}") }
    drain!
    summarize!

    assembled = Conversations::ContextAssembly.assemble(conversation: @conversation, principal: @human)

    assert_equal 30, assembled.history.compacted_count,
      "every content-bearing turn the summary replaced is still counted"
    assert_equal 1, assembled.history.selected_count, "the summary itself is the history"
    assert_equal 0, assembled.history.skipped_count
  end

  # THE LANE EVERY PRE-SEND PROTECTION IS BLIND TO. A model with no
  # declared window does not self-fit — there is nothing to fit TO — so
  # history rides unbounded and the exact-count gate never runs. The
  # sealed request's BYTE bound is the only wall left, and it was the one
  # arm no test had ever reached on this plane. Four shipped lanes count
  # no tokens; this is the shape they leave behind.
  test "a windowless lane still gets repaired, at the byte wall" do
    12.times { |n| accept!(text: "turn#{n} #{SecureRandom.hex(50_000)}") }
    drain!
    accept!(kind: "direct_reply", text: "and now what",
      provider_id: "dev", model_ref: "mock-windowless")

    drain!

    limits = ModelSelection.resolve(
      account: @account, workload: "text_generation",
      submitted: Nexus::SubmittedModelSelection.new(
        model: "dev/mock-windowless", reasoning_effort: nil
      ),
      configuration: OneShots::CoerceConfiguration.call({}),
      port: ModelSelection::Resolver.new
    ).selection.capabilities.limits
    assert_nil limits.input_token_bound,
      "if this model ever gains a window the test proves the wrong arm"
    assert_nil limits.advisory_input_bound
    assert_not_nil summary_turn,
      "with no window there is nothing to fit to, so nothing stops the " \
      "assembly before the byte bound — and the byte bound must still arm"
    assert_equal "running", summary_turn.status
    assert_equal "pending", @conversation.conversation_inputs.order(:queue_position).last.state,
      "the ask waits for its repair rather than being blocked on size"
  end

  # THE WALL BETWEEN TURNS ARMS A ONE-TASK KERNEL LOOP: the summary turn is created running with a
  # loop-backed variant, the loop's seed is the SAME summarizer task the mid-turn host appends — the
  # one INSTRUCTIONS, no tools, absorb, its own retries — and it is the deliverable by construction.
  # Nothing is admitted until the scheduler mints the step, in another process; the converger then
  # settles the turn and adopts the summary, and the assembly cut finds it exactly as it found the
  # reply-invocation summary this replaced.
  test "a wall the history caused is repaired, and the retry fits" do
    build_history!
    ask_greedily!

    assert_equal 0, drain!, "the reply did not materialize — the repair holds the lane"

    head = @conversation.conversation_inputs.sole
    assert_equal "pending", head.state,
      "the head KEEPS ITS PLACE: compaction is a hold, not a block"
    assert_nil head.blocked_reason

    turn = summary_turn
    assert_not_nil turn, "a summary turn was armed"
    assert_equal "running", turn.status
    assert_equal "user", turn.role, "a summary is material, never instruction"
    assert_equal @conversation.reload.active_turn_id, turn.id, "the lane is busy"

    speaker = turn.speaker_actor
    assert_equal "system", speaker.kind
    assert_nil speaker.user_id, "the kernel's row is nobody's own"

    variant = turn.active_variant
    assert_equal "agent_loop", variant.source, "the host row is loop-backed"
    assert_equal "dev", variant.provider_id
    assert_equal "mock-text", variant.model_ref
    agent_loop = variant.agent_loop
    assert_equal "running", agent_loop.status, "born running: the turn is the start"
    assert_equal @human.id, agent_loop.creating_user_id, "signed by the wall's author"
    assert_enqueued_with(job: AgentLoops::ScheduleJob, args: [agent_loop.id])

    summarizer = agent_loop.agent_loop_nodes.sole
    assert_equal "k1", summarizer.node_key
    assert_equal "model_task", summarizer.task_kind
    assert_equal "branch", summarizer.continuation_source, "a summarizer is not the conversation"
    assert_nil summarizer.tool_definitions, "it has one job and nothing to call"
    assert_equal "absorb", summarizer.on_failure
    assert_equal Conversations::Compaction::Summarizer::RETRIES, summarizer.retry_budget
    assert_equal summarizer.id, agent_loop.deliverable_node_id,
      "the deliverable is the summarizer by construction — the tip after the one step"
    assert_equal Conversations::Compaction::Summarizer::INSTRUCTIONS, summarizer.system_instructions,
      "the one INSTRUCTIONS, on this host as on the loop's"
    assert_equal 0, ModelInvocation.count, "nothing is admitted until the scheduler mints the step"
    assert_empty @conversation.model_invocations, "and the step is never a reply on the conversation's queue"

    schedule_loop!(agent_loop)
    invocation = ModelInvocation.find(summarizer.reload.selected_model_invocation_id)
    assert_nil invocation.conversation_id
    assert invocation.internal_creation_key.start_with?("agent_loop_step:")
    assert_equal Conversations::Compaction::Summarizer::INSTRUCTIONS, invocation.request_options["instructions"],
      "the instructions ride the system channel of the step"
    request = invocation.content_bodies.find_by!(role: "request").effective_text
    assert_includes request, Conversations::Compaction::Serialize::HEADER
    assert_includes request, "turn0 ", "the oldest exchange is in the material to summarize"
    # A single line, deliberately: `effective_text` on a message-shaped
    # body is the entry's JSON, where a newline is an escaped \\n.
    assert_includes request, Conversations::Compaction::Serialize::TAIL_HEADER.lines.first.strip,
      "the newest exchange rides under its own header"
    assert_includes request, "turn4 ", "and the newest exchange is IN it"

    # The repair settles through the loop's own chain, and the lane drains
    # again on its own.
    run_loop_round!(agent_loop, sse_success("THE SUMMARY"))
    assert_equal "completed", agent_loop.reload.status
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    assert_includes turn.active_variant.content_bodies.find_by!(role: "content")
      .effective_text, "THE SUMMARY"

    assert_equal 1, drain!, "the head materialized once history fit"
    reply = @conversation.conversation_turns.order(:position).last
    assert_equal "direct_reply", reply.kind

    sent = reply.active_variant.model_invocation
      .content_bodies.find_by!(role: "request").effective_text
    assert_includes sent, "Mock: THE SUMMARY"
    assert_includes sent, "The earlier part of this conversation was summarized",
      "the frame tells the model what it is reading"
    assert_includes sent, "and now what", "the caller's own prompt never yields"
    refute_includes sent, Conversations::Compaction::Summarizer::INSTRUCTIONS.lines.first.strip,
      "the summarizer's own instructions are not history"
    refute_includes sent, Conversations::Compaction::Serialize::HEADER,
      "nor is the summarizer's own request — the turn renders by KIND, never by its rounds"
  end

  # THE SUMMARIZER MUST FIT THE WINDOW OF THE MODEL THAT READS IT. A history
  # that walled is, by construction, larger than the window on the lane that
  # walled it — and rendered whole for the summarizer it still is. The
  # reply-invocation summarizer this replaced never counted its request
  # (the mock ignores its window; a real provider would have refused it),
  # so the between-turn repair had never been proven to fit. The step now
  # crosses the scheduler's pre-send gate like every round, where an exact
  # count fails it on size; so the arm shrinks the older section — whole
  # entries, oldest first, under the elision marker — until the request
  # counts under the bound, and the tail is never what yields.
  test "a summarizer reads what fits its own window, oldest entries elided and the tail whole" do
    build_history!(hex: UNREADABLE_TURN_HEX)
    ask_greedily!
    assert_equal 0, drain!
    agent_loop = summary_loop
    summarizer = agent_loop.agent_loop_nodes.sole

    selection = mock_text_selection
    bound = selection.capabilities.limits.input_token_bound
    prompt = summarizer.content_bodies.find_by!(role: "input").effective_text
    whole = Conversations::Compaction::Serialize.request(
      *Conversations::Compaction::Serialize.call(Conversations::Compaction::Serialize.timeline_entries(@conversation))
    )
    assert_operator ModelRequests::TokenCount.count(profile: selection.execution_profile,
      segments: [Conversations::Compaction::Summarizer::INSTRUCTIONS, whole]).tokens, :>, bound,
      "the fixture: rendered whole, the history the wall caught does not fit the summarizer either"
    counted = ModelRequests::TokenCount.count(profile: selection.execution_profile,
      segments: [Conversations::Compaction::Summarizer::INSTRUCTIONS, prompt])
    assert_predicate counted, :exact?
    assert_operator counted.tokens, :<=, bound, "what the summarizer is handed fits its window"
    assert_includes prompt, "earlier round(s) elided to fit", "and says what it does not carry"
    refute_includes prompt, "turn0 ", "the oldest exchange is what yields"
    assert_includes prompt, Conversations::Compaction::Serialize::TAIL_HEADER.lines.first.strip
    assert_includes prompt, "turn4 ", "the tail is kept whole"

    schedule_loop!(agent_loop)
    assert_equal "running", summarizer.reload.status, "the step crossed the pre-send gate"
    run_loop_round!(agent_loop, sse_success("THE SUMMARY"))
    Conversations::Turns::Converge.call
    assert_equal "completed", summary_turn.reload.status
    assert_equal 1, drain!, "and the reply goes out against the summary"
  end

  test "history begins at the summary — what it replaced never rides again" do
    build_history!
    marker = @conversation.conversation_turns.order(:position).first
      .active_variant.content_bodies.find_by!(role: "content").effective_text[0, 60]

    ask_greedily!
    drain!
    settle_summary!("THE SUMMARY")
    drain!

    sent = @conversation.conversation_turns.order(:position).last
      .active_variant.model_invocation
      .content_bodies.find_by!(role: "request").effective_text
    refute_includes sent, marker,
      "the compacted turns are gone from the wire, not merely trimmed"
  end

  test "a repair is armed at most once per wall" do
    build_history!
    ask_greedily!
    drain!

    # A summary that does not shrink anything: the retry hits the SAME
    # wall, and the head must block rather than arm a summary of a summary.
    settle_summary!(SecureRandom.hex(6_000))
    drain!

    assert_equal 1, @conversation.conversation_turns.where(kind: "compaction_summary").count,
      "compacting a compaction is a loop, not a repair"
    assert_equal 1, AgentLoop.count
    blocked = @conversation.conversation_inputs.sole
    assert_equal "blocked", blocked.state
    assert_equal "estimated_input_exceeds_model_limit", blocked.blocked_reason,
      "the head blocks on the wall that started it — a reason a caller can act on"
  end

  # A FAILED SUMMARY LOOP IS NOBODY'S HOLD TO REPAIR. The summarizer absorbs
  # and retries, and when its budget is spent the loop holds
  # `deliverable_unresolved` and the turn settles failed — which never cuts.
  # The drain's hold-behind rule reads the tail's loop, and for the
  # kernel's own row that would park a person's message behind a repair
  # nobody asked for, waiting for `rho retry` on a kernel loop: the
  # kernel's KIND is exempt, the head re-hits the wall, and blocks on size.
  test "a failed repair never replaces history with nothing, and never holds the head" do
    build_history!
    ask_greedily!
    drain!

    turn = summary_turn
    fail_summary!
    agent_loop = summary_loop
    assert_equal "needs_attention", agent_loop.reload.status
    assert_equal "deliverable_unresolved", agent_loop.attention_reason
    assert_equal "failed", turn.reload.status
    assert_equal "deliverable_unresolved", turn.active_variant.agent_loop.turn_shape.failure_reason_key

    assembled = Conversations::ContextAssembly.assemble(
      conversation: @conversation.reload, prompt: "next", principal: @human
    )
    text = assembled.messages.map { |message| message.parts.map(&:text).join }.join("\n")
    assert_includes text, "turn0 ", "a failed summary stands in for nothing"

    assert_equal 0, drain!
    head = @conversation.conversation_inputs.sole
    assert_equal "blocked", head.state, "the head is not loop_held behind the kernel's own row"
    assert_equal "estimated_input_exceeds_model_limit", head.blocked_reason
    reasons = @conversation.conversation_event_items.where(item_type: "input_blocked")
      .map { |item| item.payload["blocked_reason"] }
    refute_includes reasons, "loop_held"
    assert_equal 1, @conversation.conversation_turns.where(kind: "compaction_summary").count,
      "once per wall: the failed summary is the newest entry and fences a second"
  end

  # A REPAIR THAT RAISES MUST LEAVE THE CALLER A TRANSACTION IT CAN STILL
  # WRITE IN. The arm runs inside the drain's open transaction, so without
  # its own savepoint a raise aborts that transaction at the database and
  # the fallback — parking the head with its reason — raises
  # PG::InFailedSqlTransaction on top of it. The caller would see a crash
  # instead of a blocked head, which is the outcome it can act on.
  test "a repair that raises leaves the head blocked, not the drain broken" do
    build_history!
    ask_greedily!

    # The raise lands AFTER the turn and its variant are written, which is
    # the only shape that matters: an earlier one leaves nothing behind on
    # its own.
    AgentLoop.stub(:create!, ->(*) { raise "the loop exploded" }) do
      assert_equal 0, drain!
    end

    assert_nil summary_turn,
      "a half-built repair that COMMITTED would leave a running turn nothing " \
      "can ever settle — the lane busy forever, the conversation bricked"
    blocked = @conversation.conversation_inputs.sole
    assert_equal "blocked", blocked.state
    assert_equal "estimated_input_exceeds_model_limit", blocked.blocked_reason,
      "the head blocks on the wall that started it — the raise is the kernel's problem"
    assert_equal 0, AgentLoop.count
    assert_equal 0, ModelInvocation.count, "and nothing was sent"
  end

  # The other half of the same guard: a seed body the bounds refuse is not
  # an exception — the append door refuses it — and the turn it already
  # wrote must go with it.
  test "a repair whose request will not fit leaves nothing behind" do
    build_history!
    ask_greedily!

    ContentBodies::Replace.stub(:call, ->(**) { refused_request }) do
      assert_equal 0, drain!
    end

    assert_nil summary_turn
    assert_equal 0, AgentLoop.count
    assert_equal "blocked", @conversation.conversation_inputs.sole.state
  end

  # THE KERNEL'S ROW IS NOBODY'S TO EDIT. A summary STANDS IN FOR
  # everything before it, and the assembly cut is derived from the turn's
  # kind — so a caller rewriting one would silently replace the whole
  # history it represents with arbitrary text, and nothing downstream
  # could tell. Every other verb on this plane edits what someone
  # authored; this is the one row nobody did.
  test "a compaction summary refuses the edit verb" do
    build_history!
    ask_greedily!
    drain!
    settle_summary!("THE SUMMARY")

    summary = summary_turn
    assert_equal summary.public_id,
      @conversation.reload.conversation_turns.order(:position).last.public_id,
      "it is the tail, so only the kind can be what refuses"

    refused = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: summary.public_id,
      entries: [{ "text" => "history I invented" }], acting_user: @human
    ))
    assert_equal :kernel_authored, refused.outcome
    assert_includes summary.reload.active_variant.content_bodies
      .find_by!(role: "content").effective_text, "THE SUMMARY"
  end

  # UN-COMPACTING THROUGH A VIEW FLAG would be an API nobody designed:
  # the assembly cut is derived from what the summary IS and where it
  # sits, so hiding it silently brings back every turn it replaced. The
  # undo is not removed — the summary is the tail, and deleting the tail
  # is this plane's undo verb; its loop goes with it, tombstoned.
  test "a compaction summary refuses the view-state verbs, and delete is the undo" do
    build_history!
    ask_greedily!
    drain!
    settle_summary!("THE SUMMARY")
    summary = summary_turn

    [{ visibility: "excluded_from_context" }, { concealed: true }].each do |change|
      refused = Conversations::Turns::SetViewState.call(
        Conversations::Turns::SetViewState::Command.new(
          conversation: @conversation, turn_public_id: summary.public_id,
          acting_user: @human, visibility: change[:visibility], concealed: change[:concealed]
        )
      )
      assert_equal :kernel_authored, refused.outcome, change.inspect
    end

    deleted = Conversations::Turns::HardDelete.call(
      Conversations::Turns::HardDelete::Command.new(
        conversation: @conversation, turn_public_id: summary.public_id,
        acting_user: @human
      )
    )
    assert_predicate deleted, :accepted?,
      "the summary is the tail, and deleting the tail is how a compaction is undone"
    assert_predicate AgentLoop.sole, :tombstoned?, "the summary loop dies with its turn"
  end

  # `off` is the author's whole posture on either host: a client driving
  # its own loop wants the typed refusal, not a summary it did not ask for.
  test "a policy of off blocks the head on size between turns rather than quietly obliging" do
    declare_tools!(@agent, compaction_policy: { "mode" => "off" })
    # The agent's policy governs only a conversation it ANSWERS.
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    build_history!
    post_input!(@conversation, acting_user: @agent, kind: "direct_reply",
      text: "and now what #{SecureRandom.hex(PROMPT_HEX)}", provider_id: "dev", model_ref: "mock-text",
      context_options: { "history" => { "token_budget_share" => 1.0 } })

    assert_equal 0, drain!

    assert_nil summary_turn
    assert_equal 0, AgentLoop.count
    blocked = @conversation.conversation_inputs.sole
    assert_equal "blocked", blocked.state
    assert_equal "estimated_input_exceeds_model_limit", blocked.blocked_reason
  end

  test "the compaction is narrated, and counted apart from a trim" do
    build_history!
    head = ask_greedily!
    drain!

    item = @conversation.conversation_event_items
      .where(item_type: "context_compacted").sole
    assert_equal summary_turn.public_id, item.payload["turn_public_id"]
    assert_equal summary_loop.public_id, item.payload["agent_loop_public_id"],
      "the loop behind the summary is named, so a watcher can follow the repair"
    assert_equal summary_turn.public_id, item.payload["summary_turn_public_id"]
    assert_equal "kernel", item.payload["mode"]
    assert_equal "wall", item.payload["trigger"]
    assert_empty item.payload.keys - %w[turn_public_id agent_loop_public_id summary_turn_public_id mode trigger],
      "ONE payload for both hosts: the head's input is narrated by its own " \
      "`input_materialized` when it drains, and the turn names its variant"

    settle_summary!("THE SUMMARY")
    # The summary's own `turn_status` items — the loop's at birth and at
    # its end, the settle's — all say `compaction_summary`: the one fact a
    # follower waiting on a person's turn reads to pass the kernel's by.
    kinds = @conversation.conversation_event_items.where(item_type: "turn_status")
      .order(:sequence).map(&:payload)
      .select { |payload| payload["turn_public_id"] == summary_turn.public_id }
      .map { |payload| payload["turn_kind"] }
    assert_operator kinds.length, :>=, 2, "the loop's note and the settle's row, at least"
    assert_equal %w[compaction_summary], kinds.uniq
    history = Conversations::ContextAssembly.assemble(
      conversation: @conversation.reload, prompt: "next", principal: @human
    ).history
    assert_operator history.compacted_count, :>, 0,
      "summarized history is reported as summarized"
    assert_equal 0, history.skipped_count,
      "and never as lost — a client must be able to tell the two apart"
  end

  # NEITHER STEERS NOR THE SPINE EVER TOUCH THE SUMMARIZER HOST. A steer needs a reply to redirect;
  # the one active turn is the kernel's summary, so the words fall back to the queue unbound, the
  # summarizer's request is minted without peeking at them, the loop has no queue of its own to
  # plant a follow-up round from, and the words ride the timeline as the next message once the lane
  # is idle again.
  test "a steer posted during a between-turn summary queues and the summarizer never peeks" do
    build_history!
    ask_greedily!
    drain!
    agent_loop = summary_loop
    assert_equal "running", agent_loop.status

    steer = accept!(delivery_mode: "steer", text: "the number is 41")
    assert_equal "pending", steer.state, "no reply in flight to redirect: the words queue"
    assert_nil steer.steering_target_turn_id

    schedule_loop!(agent_loop)
    summarizer = agent_loop.agent_loop_nodes.sole
    sealed = sealed_request_entries(ModelInvocation.find(summarizer.reload.selected_model_invocation_id))
    refute_includes sealed.to_json, "the number is 41",
      "a summarizer reads history, never a person's words"

    run_loop_round!(agent_loop, sse_success("THE SUMMARY"))
    assert_equal "completed", agent_loop.reload.status
    assert_equal 1, agent_loop.agent_loop_nodes.count,
      "no planted round: a loop-backed loop has no queue, and nothing bound to the kernel's turn"
    Conversations::Turns::Converge.call
    assert_equal "completed", summary_turn.reload.status
    assert_equal "pending", steer.reload.state, "still waiting its turn on the queue"

    assert_equal 1, drain!, "the greedy reply materializes first — FIFO"
    settle_reply!("the answer")
    assert_equal 1, drain!
    last = @conversation.conversation_turns.order(:position).last
    assert_equal "message", last.kind
    assert_includes last.active_variant.content_bodies.find_by!(role: "content").effective_text,
      "the number is 41", "the words ride the timeline as the next message"
  end

  # THE SUMMARY TURN'S ANSWERER: the kernel's between-turn summary is loop-backed, so its turn
  # carries the conversation's DEFAULT answerer at that moment — the summary loop then derives what
  # `declared_tools` read — even when the head that armed it was addressed to another agent.
  test "the between-turn summary turn takes the conversation's default answerer, whoever the head addressed" do
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    peer = create_agent_member(display_name: "Peer", agent_identifier: "peer-agent")
    build_history!
    ask_greedily!(answering_user_public_id: peer.public_id)
    drain!

    assert_equal @agent, summary_turn.answering_user, "the default, not the head's addressee"
    assert_equal @agent, summary_loop.answering_user
    assert_equal @agent, summary_loop.declaring_profile
    assert_equal "running", summary_turn.status
  end
end
