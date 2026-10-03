require "test_helper"
require "test_helpers/agent_loops_mail_test_helper"

# A BACKGROUND TASK MAY OUTLIVE ITS TURN: a loop-backed turn's reply is final when the deliverable
# answers and no foreground work remains — `delivered_at`, the turn settles on it — while the orphan
# stays the loop's own; its answer is kernel mail through the input door: a kernel-stamped
# `direct_reply` that always QUEUES (a running turn finishes first), drains FIRST, and WAKES an idle
# conversation — a new turn on the mailing loop's own surface whose trailing user message is the
# receipt. A standalone loop has no later turn and keeps the wake. Driven through the REAL chain.
class AgentLoops::MailTest < ActiveJob::TestCase
  include AgentLoopsMailTestHelper

  # ── (1) the reply is final, the loop is not ─────────────────────────────

  test "the deliverable answers with a background branch running: delivered, the loop running, no wake" do
    turn, agent_loop = delivered_turn!

    assert_predicate agent_loop, :delivered?
    assert_equal "running", agent_loop.status, "the orphan is the loop's own until it settles"
    assert_equal "running", loop_node(agent_loop, "r2t0-model-1").status
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "w1"), "no round after a final reply"
    assert_equal "completed", agent_loop.turn_shape.status
    assert_equal "running", turn.reload.status, "the loop lock never writes the turn's row"

    assert_equal 1, converge!.value[:recorded], "the delivered_at write woke the converger"
    assert_equal "completed", turn.reload.status
    assert_equal "Mock: meanwhile, here is what I know",
      turn.active_variant.content_bodies.find_by!(role: "content").effective_text,
      "the deliverable's output is adopted on delivery"
    assert_nil @conversation.reload.active_turn_id, "the lane is idle again"
    assert_equal 0, converge!.value[:recorded], "off the frontier once settled"
  end

  test "a detached nested race mails each winner once and excludes a later run out answer" do
    turn, agent_loop = open_turn!("compare approaches in the background")
    step = AgentLoops::Tasks::Step
    branches = %w[a b c].to_h do |key|
      [key, step::Model.new(key: key, prompt: "approach #{key}", model: MOCK_MODEL, on_failure: "absorb")]
    end
    inner = step::Parallel.new(members: branches.values_at("a", "b"), until: "any",
      losers: "run_out", key: "inner", on_failure: "absorb")
    result = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
      agent_loop: agent_loop, steps: [step::Parallel.new(members: [inner, branches.fetch("c")],
        until: 2, key: "outer", on_failure: "absorb")],
      tip: AgentLoops::Tasks::Tip.seed("branch").with(detached: true), origin: "model"
    ))
    assert_predicate result, :applied?, result.outcome.inspect
    schedule_loop!(agent_loop)
    run_round!(agent_loop, "r1", "the comparison will follow")
    converge!
    assert_equal "completed", turn.reload.status

    run_round!(agent_loop, "a", "first answer")
    run_round!(agent_loop, "c", "second answer")
    assert_equal "running", loop_node(agent_loop, "b").status
    assert_equal [:mailed, :mailed], AgentLoops::Mail.call(agent_loop.reload)
    assert_equal [
      envelope("a", "completed", "approach a", "Mock: first answer"),
      envelope("c", "completed", "approach c", "Mock: second answer"),
    ], @conversation.conversation_inputs.order(:queue_position).map(&:text)
    assert_not_nil loop_node(agent_loop, "a").mailed_at
    assert_not_nil loop_node(agent_loop, "c").mailed_at

    run_round!(agent_loop, "b", "late answer")
    assert_empty AgentLoops::Mail.call(agent_loop.reload)
    assert_empty AgentLoops::Mail.call(agent_loop.reload)
    assert_equal 2, @conversation.conversation_inputs.count
    assert_nil loop_node(agent_loop, "b").mailed_at
  end

  # ── (2) the branch settles → mail, the loop completes ───────────────────

  test "the orphan's answer is mailed through the input door and read by the next turn" do
    turn, agent_loop = delivered_turn!
    converge!

    assert_enqueued_with(job: AgentLoops::MailJob, args: [agent_loop.id]) do
      run_round!(agent_loop, "r2t0-model-1", "all green")
    end
    assert_equal "completed", agent_loop.reload.status, "nothing remains on the loop"
    assert_equal "completed", turn.reload.status, "the settled variant is never rewritten"

    mail_now!(agent_loop)
    mail = @conversation.conversation_inputs.sole
    assert_equal %w[direct_reply user queue pending], [mail.kind, mail.role, mail.delivery_mode, mail.state],
      "a queued reply, never a steer"
    variant = agent_loop.conversation_turn_variant
    assert_equal [variant.provider_id, variant.model_ref], [mail.provider_id, mail.model_ref],
      "the receipt runs on the mailing loop's own model"
    assert_equal %w[ask read_file task], mail.tool_names, "the receipt freezes even the source's full set"
    assert_equal ConversationInput::TASK_RESULT_ORIGIN, mail.origin
    assert_equal @conversation.public_id, mail.sender_conversation_public_id
    assert_equal envelope("r2t0", "completed", "long test run", "Mock: all green"), mail.text
    assert_equal @agent.id, mail.authoring_user_id, "sent as the loop's creator"
    assert_not_nil loop_node(agent_loop, "r2t0-model-1").reload.mailed_at
    accepted = @conversation.conversation_event_items.where(item_type: "input_accepted")
      .order(:sequence).last.payload
    assert_equal "task_result", accepted.fetch("origin")
    assert_equal agent_loop.public_id, accepted.fetch("agent_loop_public_id")
    assert_equal "r2t0", accepted.fetch("task_key"), "the key the model saw, never the branch's"
    assert_equal 0, @conversation.conversation_inputs.caller_authored.count,
      "kernel mail is not counted against the caller's bound"
    assert_equal "r2t0-model-1",
      AgentAPI::AgentLoopPhasesPresenter.call(agent_loop).background.sole.fetch(:key)
    assert_not_nil AgentAPI::AgentLoopPhasesPresenter.call(agent_loop).background.sole.fetch(:mailed_at)
    assert_not_nil AgentAPI::AgentLoopPresenter.task(loop_node(agent_loop, "r2t0-model-1").reload)[:mailed_at]

    mail_now!(agent_loop)
    assert_equal 1, @conversation.conversation_inputs.count, "level-triggered: mailed once"

    # Idle, the receipt WAKES the conversation: a loop-backed turn under
    # the same declaring agent whose round one reads the envelope as its
    # trailing user message — the model finishes absorbing what it asked
    # for before it takes new instructions.
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    woken_turn = @conversation.conversation_turns.order(:position).last
    assert_equal %w[direct_reply assistant running], [woken_turn.kind, woken_turn.role, woken_turn.status]
    assert_equal "agent_loop", woken_turn.active_variant.source
    assert_equal "task_result", woken_turn.origin
    assert_equal woken_turn.id, @conversation.reload.active_turn_id, "the receipt started a turn"
    woken = woken_turn.active_variant.agent_loop
    assert_equal @agent.id, woken.creating_user_id, "under the same declaring agent"
    # The wake's narration is the ordinary pair: `input_materialized` names
    # the receipt, `turn_status` beside it names the woken loop.
    materialized = @conversation.conversation_event_items.where(item_type: "input_materialized")
      .order(:sequence).last.payload
    assert_equal mail.public_id, materialized.fetch("input_public_id")
    assert_equal woken_turn.public_id, materialized.fetch("turn_public_id")
    started = @conversation.conversation_event_items.where(item_type: "turn_status")
      .order(:sequence).last.payload
    assert_equal woken.public_id, started.fetch("agent_loop_public_id")
    schedule_loop!(woken)
    assert_equal envelope("r2t0", "completed", "long test run", "Mock: all green"),
      request_texts(loop_node(woken, "r1")).last,
      "the receipt IS the woken turn's trailing user message"

    # A woken turn with nothing to do ends and wakes nothing (risk 1): the
    # wake is level-triggered, bounded by what bounds a turn.
    assert_no_enqueued_jobs(only: AgentLoops::MailJob) do
      run_round!(woken, "r1", "noted")
      converge!
    end
    assert_equal "completed", woken.reload.status
    assert_equal "completed", woken_turn.reload.status
    assert_nil @conversation.reload.active_turn_id
    assert_equal 0, @conversation.conversation_inputs.count

    # THE DELIVERY IN LATER HISTORY: the woken turn renders as its seed — the envelope, in the user
    # role — then its answer, and the envelope is in the next turn's request exactly once.
    post_input!(@conversation, acting_user: @human, kind: "direct_reply", text: "and?",
      provider_id: "dev", model_ref: "mock-text")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    texts = reply_texts
    delivery = envelope("r2t0", "completed", "long test run", "Mock: all green")
    assert_equal 1, texts.join("\n").scan(delivery).length, "the woken turn's seed, and nowhere else"
    assert_operator texts.index(delivery), :<, texts.index("Mock: noted"),
      "the receipt reads before the answer it prompted"
    assert_equal "and?", texts.last
  end

  # THE WOKEN TURN APPENDS: the kernel's receipt carries no per-turn text of its own, and the
  # mailing turn's — its developer lead — rides history where that turn's request placed it, so
  # the woken round one is the mailing loop's LAST request whole, its answer, then the receipt:
  # nothing ahead of it edited, every thinking block it carried still signed under the same prefix.
  test "the woken turn's round one is the mailing turn's LAST request plus its answer, then the receipt" do
    lead = "Relative paths resolve against /w."
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "run the suite",
        model_ref: DevModelLane::WINDOWED_TEXT_MODEL.split("/", 2).last,
        context_options: { "inline" => [{ "role" => "developer", "position" => "lead", "text" => lead }] })
      schedule_loop!(agent_loop)
      apply_via(attempt_for(agent_loop, "r1"), sse_success("delegating", reasoning: "plan one",
        reasoning_encrypted: "blob-one", tool_calls: [
          { id: "call_task", name: "task", arguments: { prompt: "long test run" }.to_json },
        ]))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ScheduleJob]) do
        AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      end
      apply_via(attempt_for(agent_loop, "r2"), sse_success("meanwhile", reasoning: "plan two",
        reasoning_encrypted: "blob-two"))
      AgentLoops::ConvergeTerminalSteps.call
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      converge!
      assert_equal "completed", turn.reload.status
      last = round_request_entries(loop_node(agent_loop, "r2"))
      assert_equal [["developer", lead], ["user", "run the suite"]],
        last.first(2).map { |payload| [payload["role"], payload.dig("parts", 0, "text")] }

      run_round!(agent_loop, "r2t0-model-1", "all green")
      mail_now!(agent_loop)
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      woken = @conversation.conversation_turns.order(:position).last.active_variant.agent_loop
      schedule_loop!(woken)
      entries = round_request_entries(loop_node(woken, "r1"))

      canonical = ->(list) { list.map { |payload| Nexus::CanonicalJson.encode(payload) } }
      assert_equal canonical.(last), canonical.(entries).first(last.length),
        "the woken prefix is the mailing loop's last request whole: its lead, its words, round one's thinking"
      answer = entries.drop(last.length)
      assert_equal ["reasoning_item", nil], [answer.first["type"], answer.first["role"]]
      assert_equal "blob-two", answer.first.dig("payload", "encrypted_content")
      assert_equal [["assistant", "Mock: meanwhile"],
                    ["user", envelope("r2t0", "completed", "long test run", "Mock: all green")]],
        answer.drop(1).map { |payload| [payload["role"], payload.dig("parts", 0, "text")] },
        "then its answer, then the receipt as the trailing user message — no lead of its own"
      assert_equal 1, canonical.(entries).join.scan("/w.").length, "the lead rides once, where it was sent"
    end
  end

  test "a steer arriving after delivery queues when the turn settles while its background work continues" do
    turn, agent_loop = delivered_turn!
    assert_predicate agent_loop, :delivered?
    assert_equal "running", agent_loop.status
    assert_equal "running", turn.reload.status
    steer = post_input!(@conversation, acting_user: @human, text: "also explain the failures",
      delivery_mode: "steer")

    assert_equal 1, converge!.value[:recorded]
    assert_equal "completed", turn.reload.status
    assert_equal "running", agent_loop.reload.status
    assert_equal "pending", steer.reload.state
    assert_nil steer.steering_target_turn_id

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal "also explain the failures", @conversation.conversation_turns.order(:position).last
      .active_variant.content_bodies.find_by!(role: "content").effective_text
    assert_equal "running", loop_node(agent_loop, "r2t0-model-1").reload.status
  end

  test "a turn that narrowed its tools is woken under the same subset" do
    say!("run the suite while I keep working")
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: nil,
      tool_names: %w[read_file task])
    schedule_loop!(agent_loop)
    call_round!(agent_loop, "r1", "task", { prompt: "long test run" })
    run_round!(agent_loop, "r2", "meanwhile, here is what I know")
    converge!
    assert_equal "completed", turn.reload.status
    run_round!(agent_loop, "r2t0-model-1", "all green")

    mail_now!(agent_loop)
    mail = @conversation.conversation_inputs.sole
    assert_equal %w[read_file task], mail.tool_names, "the receipt carries the turn's narrowed set"

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    woken = @conversation.conversation_turns.order(:position).last.active_variant.agent_loop
    assert_equal %w[read_file task], AgentLoops::BranchTools.names(loop_node(woken, "r1"))
  end

  test "a receipt whose allowed tools were removed wakes with no tools and refuses a newly declared call" do
    _turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent,
      text: "run the task while I keep working", tool_names: %w[task])
    schedule_loop!(agent_loop)
    call_round!(agent_loop, "r1", "task", { prompt: "long test run" })
    run_round!(agent_loop, "r2", "the result will follow")
    converge!
    run_round!(agent_loop, "r2t0-model-1", "all green")
    declare_tools!(@agent, tools: [READ_TOOL])

    mail_now!(agent_loop.reload)
    mail = @conversation.conversation_inputs.sole
    assert_equal [], mail.tool_names, "an empty intersection must not mean the whole declaration"
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    woken = @conversation.conversation_turns.order(:position).last.active_variant.agent_loop
    assert_empty AgentLoops::BranchTools.names(loop_node(woken, "r1"))

    schedule_loop!(woken)
    call_round!(woken, "r1", "read_file", { path: "/owner/private.txt" })
    call = loop_node(woken, "r2t0")
    assert_equal "failed", call.status
    assert_equal "unknown_tool", call.error_key
    assert_nil call.addressed_executor_id, "the excluded call never reaches an executor"
  end

  test "a receipt preserves the allowed canonical tool when its profile changes the alias" do
    _turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent,
      text: "run the task while I keep working", tool_names: %w[task])
    schedule_loop!(agent_loop)
    call_round!(agent_loop, "r1", "task", { prompt: "long test run" })
    run_round!(agent_loop, "r2", "the result will follow")
    converge!
    run_round!(agent_loop, "r2t0-model-1", "all green")
    declare_tools!(@agent, tools: [AGENT_ALIAS, READ_TOOL])

    mail_now!(agent_loop.reload)
    assert_equal %w[Agent], @conversation.conversation_inputs.sole.tool_names
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    woken = @conversation.conversation_turns.order(:position).last.active_variant.agent_loop
    assert_equal %w[Agent], AgentLoops::BranchTools.names(loop_node(woken, "r1"))
  end

  test "a queued receipt cannot acquire tools added after it was mailed" do
    _turn, agent_loop = delivered_turn!
    converge!
    run_round!(agent_loop, "r2t0-model-1", "all green")
    mail_now!(agent_loop)
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, Nexus::Tools::ASK, READ_TOOL, Nexus::Tools::SPAWN])

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    woken = @conversation.conversation_turns.order(:position).last.active_variant.agent_loop
    assert_equal %w[ask read_file task], AgentLoops::BranchTools.names(loop_node(woken, "r1"))
  end

  test "a person's reply queued before the receipt reads after it" do
    _turn, agent_loop = delivered_turn!
    converge!
    next_turn, next_loop = open_turn!("meanwhile, read the notes")
    person = post_input!(@conversation, acting_user: @human, text: "what did it find?",
      kind: "direct_reply", provider_id: "dev", model_ref: "mock-text")
    run_round!(agent_loop, "r2t0-model-1", "all green")
    assert_equal [:mailed], AgentLoops::Mail.call(agent_loop.reload)
    receipt = @conversation.conversation_inputs.where.not(id: person.id).sole
    assert_operator person.queue_position, :<, receipt.queue_position, "the person arrived first"
    assert_equal [receipt, person], @conversation.conversation_inputs.in_read_order.to_a,
      "kernel origin reads first, then arrival"

    run_round!(next_loop, "r1", "the notes, read")
    converge!
    assert_equal "completed", next_turn.reload.status
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    woken = @conversation.conversation_turns.order(:position).last.active_variant.agent_loop
    schedule_loop!(woken)
    assert_equal envelope("r2t0", "completed", "long test run", "Mock: all green"),
      request_texts(loop_node(woken, "r1")).last, "the receipt's turn comes first"
    assert_equal "pending", person.reload.state, "the person's word waits its turn"

    run_round!(woken, "r1", "noted")
    converge!
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    persons_turn = @conversation.conversation_turns.order(:position).last
    assert_equal "person", persons_turn.origin
    assert_equal "running", persons_turn.status
    assert_not ConversationInput.exists?(person.id)
    texts = reply_texts
    assert_equal 1, texts.join("\n").scan(envelope("r2t0", "completed", "long test run", "Mock: all green")).length,
      "the person's turn reads the receipt once, as the woken turn's seed"
    assert_equal "what did it find?", texts.last
  end

  test "an archived conversation admits the receipt and wakes at unarchive" do
    _turn, agent_loop = delivered_turn!
    converge!
    run_round!(agent_loop, "r2t0-model-1", "all green")
    @conversation.reload.update!(archived_at: Time.current)

    assert_equal [:mailed], AgentLoops::Mail.call(agent_loop.reload)
    assert_equal :not_available,
      Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    assert_equal "pending", @conversation.conversation_inputs.sole.state

    @conversation.reload.update!(archived_at: nil)
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal "agent_loop", @conversation.conversation_turns.order(:position).last.active_variant.source
  end

  # A provider disappearing after delivery must not strand the immutable
  # queue head or erase its result: a recoverable loop owns the held receipt.
  test "a receipt whose provider is disabled becomes a visible recoverable hold" do
    _turn, agent_loop = delivered_turn!
    converge!
    run_round!(agent_loop, "r2t0-model-1", "all green")
    ModelProviderPolicy.find_by!(account: @account, provider_id: "dev").update!(enabled: false)

    assert_equal [:mailed], AgentLoops::Mail.call(agent_loop.reload)
    assert_equal "mock-text", @conversation.conversation_inputs.sole.model_ref
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    landed = @conversation.conversation_turns.order(:position).last
    receiving_loop = landed.active_variant.agent_loop
    schedule_loop!(receiving_loop)
    converge!
    assert_equal %w[direct_reply assistant failed], [landed.kind, landed.role, landed.reload.status]
    assert_equal "needs_attention", receiving_loop.reload.status
    assert_equal "provider_disabled", loop_node(receiving_loop, "r1").error_key
    assert_equal "task_result", landed.origin
    assert_equal envelope("r2t0", "completed", "long test run", "Mock: all green"),
      landed.active_variant.content_bodies.find_by!(role: "prompt").effective_text
    assert_nil @conversation.reload.active_turn_id
    assert_equal 0, @conversation.conversation_inputs.count
    assert_empty @conversation.conversation_event_items.where(item_type: "input_blocked")
  end

  # ── (3) a standalone loop keeps the wake ────────────────────────────────

  test "a standalone loop delivers by the wake and is delivered only at completion" do
    agent_loop = seed(model("answer"), detached(tool("side")))
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    clear_enqueued_jobs
    schedule_loop!(agent_loop)
    run_round!(agent_loop, "answer", "the answer")
    assert_equal "running", agent_loop.reload.status
    assert_nil agent_loop.delivered_at, "no later turn to deliver into"

    AgentLoops::Parks::Settle.call(node: loop_node(agent_loop, "side"), trusted: true,
      content: "done", outcome: "completed")
    assert_no_enqueued_jobs(only: AgentLoops::MailJob) { schedule_loop!(agent_loop) }
    assert_equal %w[answer side], loop_node(agent_loop, "w1").input_from_node_keys
    run_round!(agent_loop, "w1", "noted")
    agent_loop.reload
    assert_equal "completed", agent_loop.status
    assert_not_nil agent_loop.delivered_at
    assert_equal [], AgentLoops::Mail.call(agent_loop)
  end

  # ── (4) a refused mail is retried; a retried job replays ────────────────

  test "a mail the bound refuses leaves the tip unmailed for the next job; a replay mints no second row" do
    _turn, agent_loop = delivered_turn!
    converge!
    run_round!(agent_loop, "r2t0-model-1", "all green")
    @conversation.reload.update!(input_queue_limit: 1)
    blocker = say!("hold the queue")

    assert_no_enqueued_jobs(only: AgentLoops::MailJob) { mail_now!(agent_loop) }
    assert_equal [blocker], @conversation.conversation_inputs.to_a, "refused synchronously, nothing written"
    assert_nil loop_node(agent_loop, "r2t0-model-1").reload.mailed_at

    blocker.destroy!
    perform_enqueued_jobs(only: AgentLoops::MailJob) { AgentLoops::ScheduleSweepJob.perform_now }
    assert_equal 1, @conversation.conversation_inputs.count
    tip = loop_node(agent_loop, "r2t0-model-1").reload
    assert_not_nil tip.mailed_at

    AgentLoopNode.where(id: tip.id).update_all(mailed_at: nil)
    assert_equal [:mailed], AgentLoops::Mail.call(agent_loop.reload)
    assert_equal 1, @conversation.conversation_inputs.count, "the receipt replays the committed row"
    assert_not_nil tip.reload.mailed_at
  end

  # ── (5) a hold after delivery is the loop's alone ───────────────────────

  test "an orphan's expired ask after delivery holds the loop and leaves the turn untouched" do
    turn, agent_loop = delivered_turn!
    converge!
    call_round!(agent_loop, "r2t0-model-1", "ask", { prompt: "Which database?" })
    ask = agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::AwaitTask.sti_name).sole
    assert_equal "awaiting_input", ask.status
    assert_equal "awaiting_human", agent_loop.reload.attention_reason, "a parked question in an orphan is listed"
    assert_equal "completed", turn.reload.status

    AgentLoopNode.where(id: ask.id).update_all(await_started_at: 2.days.ago)
    assert_predicate AgentLoops::Parks::Settle.call(node: ask.reload, timeout: true), :applied?
    AgentLoops::EvaluateQuiescence.call(agent_loop.reload)
    AgentLoops::EvaluateQuiescence.call(agent_loop.reload)
    agent_loop.reload
    assert_equal "needs_attention", agent_loop.status
    assert_equal "halt_failure", agent_loop.attention_reason
    assert_equal 0, converge!.value[:recorded], "no arm matches a delivered loop's hold"
    assert_equal "completed", turn.reload.status
    assert_equal "completed", turn.active_variant.status
    announced = @conversation.conversation_event_items.where(item_type: "attention_required")
      .order(:sequence).last.payload
    assert_equal "halt_failure", announced.fetch("reason")
    assert_equal [ask.node_key], announced.fetch("blocked_task_keys")
  end

  # ── the in-flight case: the receipt never steers; turn N+1 finishes first ──

  test "a mail accepted while the next turn runs waits pending and is the turn after it" do
    _turn, agent_loop = delivered_turn!
    converge!
    next_turn, next_loop = open_turn!("meanwhile, read the notes")
    apply_via(attempt_for(next_loop, "r1"), sse_success("reading", tool_calls: [
      { id: "call_read", name: "read_file", arguments: '{"path":"notes"}' },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule_loop!(next_loop)
    assert_equal "queued", loop_node(next_loop, "r2").status

    run_round!(agent_loop, "r2t0-model-1", "all green")
    assert_equal [:mailed], AgentLoops::Mail.call(agent_loop.reload)
    mail = @conversation.conversation_inputs.sole
    assert_equal "pending", mail.state, "the receipt never steers"
    assert_nil mail.steering_target_turn_id

    AgentLoops::Parks::Settle.call(node: loop_node(next_loop, "r2t0"), trusted: true,
      content: "the notes", outcome: "completed")
    schedule_loop!(next_loop)
    texts = request_texts(loop_node(next_loop, "r2"))
    assert_not_includes texts.join, "<task_result", "the running turn's continuation never carries the envelope"
    assert_equal 1, @conversation.conversation_inputs.count

    run_round!(next_loop, "r2", "the notes, read")
    converge!
    assert_equal "completed", next_turn.reload.status
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    woken = @conversation.conversation_turns.order(:position).last.active_variant.agent_loop
    schedule_loop!(woken)
    assert_equal envelope("r2t0", "completed", "long test run", "Mock: all green"),
      request_texts(loop_node(woken, "r1")).last, "the receipt is the next turn"
    assert_equal 0, @conversation.conversation_inputs.count
  end

  # ── the successor: REPLACE exempts a delivered loop ─────────────────────

  test "the person's next word does not replace a delivered loop still finishing background work" do
    _turn, agent_loop = delivered_turn!
    converge!
    say!("and now something else")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)

    assert_equal 0, converge!.value[:recorded]
    assert_equal "running", agent_loop.reload.status, "a delivered loop behind a successor is not replaced"
    assert_equal "running", loop_node(agent_loop, "r2t0-model-1").status
  end

  test "a fast background task still starts a supplementary turn after the original answer" do
    turn, agent_loop = open_turn!("run the suite while I keep working")
    call_round!(agent_loop, "r1", "task", { prompt: "long test run" })
    run_round!(agent_loop, "r2t0-model-1", "all green")
    mail_now!(agent_loop)
    assert_empty @conversation.conversation_inputs.reload
    refute_predicate agent_loop.reload, :delivered?

    assert_enqueued_with(job: AgentLoops::MailJob, args: [agent_loop.id]) do
      run_round!(agent_loop, "r2", "my original answer")
    end
    assert_predicate agent_loop.reload, :delivered?
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "w1")
    converge!
    assert_equal "Mock: my original answer", turn.reload.active_variant.content_bodies.find_by!(role: "content").effective_text
    assert_empty request_texts(loop_node(agent_loop, "r2")).grep(/Mock: all green/)

    2.times { mail_now!(agent_loop) }
    assert_equal envelope("r2t0", "completed", "long test run", "Mock: all green"),
      @conversation.conversation_inputs.reload.sole.text
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    supplementary = @conversation.conversation_turns.order(:position).last
    assert_not_equal turn.id, supplementary.id
    assert_equal "task_result", supplementary.origin
    assert_equal 1, reply_texts.join.scan(/Mock: all green/).length
    assert_empty AgentLoops::WakeContinuation.undelivered(agent_loop.reload)
  end

  test "a task started with wait true joins the current answer without supplementary mail" do
    turn, agent_loop = open_turn!("review before answering")
    call_round!(agent_loop, "r1", "task", { prompt: "review", wait: true })
    assert_equal "queued", loop_node(agent_loop, "r2").status
    run_round!(agent_loop, "r2t0-model-1", "review result")
    mail_now!(agent_loop)
    assert_empty @conversation.conversation_inputs.reload
    assert_includes round_request_entries(loop_node(agent_loop, "r2")).to_json, "review result"
    run_round!(agent_loop, "r2", "answer using the review")
    converge!
    assert_equal "completed", turn.reload.status
    assert_empty AgentLoops::WakeContinuation.undelivered(agent_loop.reload)
    mail_now!(agent_loop)
    assert_empty @conversation.conversation_inputs.reload
  end

  test "a supplementary reply reaching quiescence after its source stops cannot publish" do
    _turn, source = delivered_turn!
    converge!
    run_round!(source, "r2t0-model-1", "background result")
    mail_now!(source)
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    supplementary = @conversation.reload.active_turn.active_variant.agent_loop
    schedule_loop!(supplementary)
    attempt = attempt_for(supplementary, "r1")
    built = build(attempt)
    assert_predicate built, :built?
    started = start(attempt)
    assert_predicate AgentLoops::Stop.stop_now(source), :accepted?

    # The provider was already started when the source cut landed. Apply its
    # late result through the real chain; publication still owes the source check.
    fake_dispatch(sse_success("a late supplementary answer")) do
      sent = ModelInvocations::Dispatch.call(
        attempt: started.attempt, context: started.context, request: built.request)
      ModelInvocations::ApplyResult.call(attempt: started.attempt, outcome: sent)
    end
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    assert_equal "completed", loop_node(supplementary, "r1").status
    assert_enqueued_with(job: AgentLoops::ScheduleJob, args: [supplementary.id]) do
      supplementary.with_lock { AgentLoops::EvaluateQuiescence.call(supplementary) }
    end
    refute_predicate supplementary.reload, :delivered?
    assert_equal "running", supplementary.status, "quiescence defers the stop to the scheduler's lock boundary"

    schedule_loop!(supplementary)
    assert_predicate supplementary.reload, :stopped?
    assert_equal "canceled", supplementary.status
    refute_predicate supplementary, :delivered?
    assert_empty AgentLoops::Mail.call(supplementary)
  end

  # Turn-owned results are consumed in-loop, even when they finish first.

  # A turn-owned task completing while the spine still runs is drained into the next round — that IS
  # acceptance, and the feed owes it the same `input_accepted{origin: task_result}` item a woken
  # turn gets: persisted facts are rows + events, and a reader of the feed must see every receipt.
  # Once per tip, on either path — a tip the wake read is never mailed.
  test "a turn-owned receipt drained in-loop narrates the same input_accepted item as a woken one, once" do
    turn, agent_loop = open_turn!("run the suite while I keep working")
    call_round!(agent_loop, "r1", "task", { prompt: "long test run", lifetime: "turn" })
    run_round!(agent_loop, "r2t0-model-1", "all green")
    assert_not_nil loop_node(agent_loop, "r2t0-model-1").reload.completed_at
    assert_nil agent_loop.reload.delivered_at, "the reply is not final: r2 still runs"
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "w1"), "the spine is live: nothing is drained yet"
    assert_empty @conversation.conversation_event_items.where(item_type: "input_accepted")
      .select { |item| item.payload["origin"] == "task_result" }, "nothing accepted before the drain"

    run_round!(agent_loop, "r2", "meanwhile, here is what I know")
    wake = loop_node(agent_loop, "w1")
    assert_equal %w[r2 r2t0-model-1], wake.input_from_node_keys, "the drain: the next round reads the settled tip"
    assert_nil agent_loop.reload.delivered_at, "the wake round is the deliverable now"

    accepted = @conversation.conversation_event_items.where(item_type: "input_accepted").order(:sequence)
      .select { |item| item.payload["origin"] == "task_result" }
    assert_equal 1, accepted.length, "ONE item for the one receipt"
    assert_equal({ "origin" => "task_result", "agent_loop_public_id" => agent_loop.public_id, "task_key" => "r2t0",
                   "turn_public_id" => agent_loop.conversation_turn.public_id,
                   "variant_public_id" => agent_loop.conversation_turn_variant.public_id },
      accepted.sole.payload, "the woken turn's shape, minus the input row it never needed")
    assert_equal 0, @conversation.conversation_inputs.count, "an in-loop drain is a graph read, not an input row"

    run_round!(agent_loop, "w1", "the suite is green, so we are done")
    assert_equal "completed", agent_loop.reload.status
    assert_not_nil agent_loop.delivered_at
    assert_not AgentLoops::Mail.pending?(agent_loop), "a tip the wake read is never mailed"
    mail_now!(agent_loop)
    assert_equal 0, @conversation.conversation_inputs.count
    assert_equal 1, @conversation.conversation_event_items.where(item_type: "input_accepted")
      .count { |item| item.payload["origin"] == "task_result" }, "still one: never a second item on the mail path"
    converge!
    assert_equal "completed", turn.reload.status
  end

  # ── the person-side cancel reaches an orphan, and its cancel is mailed ──

  test "cancelling a delivered loop's orphan mails its canceled envelope" do
    _turn, agent_loop = delivered_turn!
    converge!

    canceled = AgentLoops::CancelBranch.call(AgentLoops::CancelBranch::Command.new(
      agent_loop: agent_loop, task_key: "r2t0", acting_user: @human
    ))
    assert_predicate canceled, :accepted?
    clear_enqueued_jobs
    assert_enqueued_with(job: AgentLoops::MailJob, args: [agent_loop.id]) do
      AgentLoops::ConvergeTerminalSteps.call
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    tip = loop_node(agent_loop, "r2t0-model-1")
    assert_equal %w[canceled task_canceled canceled], [tip.status, tip.error_key, tip.failure_resolution]
    assert_equal "completed", agent_loop.reload.status
    mail_now!(agent_loop)
    assert_equal envelope("r2t0", "canceled", "long test run", AgentLoops::TaskResultEnvelope::CANCELED),
      @conversation.conversation_inputs.sole.text
  end

  # THE RECEIPT'S ADDRESSEE: a background task A started answers to A's turn — the mailing loop's
  # own answerer on the one Command member — never to the conversation's default; the door never
  # judges the kernel's mail for eligibility.
  test "the receipt is addressed to the mailing loop's answerer, not the conversation's default" do
    plain = Conversation.create!(workspace: @workspace, creating_user: @human)
    @conversation = plain
    say!("history")
    post_input!(plain, acting_user: @human, kind: "direct_reply", text: "run the suite while I keep working",
      provider_id: "dev", model_ref: "mock-text", answering_user_public_id: @agent.public_id)
    Conversations::Inputs::ApplyNext.drain(conversation_id: plain.id)
    turn = plain.conversation_turns.order(:position).last
    agent_loop = turn.active_variant.agent_loop
    assert_equal [@agent, @human], [agent_loop.answering_user, plain.answering_user]
    schedule_loop!(agent_loop)
    call_round!(agent_loop, "r1", "task", { prompt: "long test run" })
    run_round!(agent_loop, "r2", "meanwhile, here is what I know")
    converge!
    run_round!(agent_loop, "r2t0-model-1", "all green")
    plain.conversation_access_entries.create!(user: @agent, level: "read")

    mail_now!(agent_loop)
    mail = plain.conversation_inputs.sole
    assert_equal [@agent, "task_result", @human], [mail.answering_user, mail.origin, mail.authoring_user],
      "addressed to the loop's answerer, authored by the loop's creator, admitted past the level"

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: plain.id)
    woken = plain.conversation_turns.order(:position).last
    assert_equal [@agent, "agent_loop"], [woken.answering_user, woken.active_variant.source],
      "the receipt woke the agent's turn on the Human's conversation"
  end
end
