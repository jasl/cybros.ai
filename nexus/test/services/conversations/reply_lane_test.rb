require "test_helper"
require "test_helpers/log_capture"

# The reply lane end to end, through the REAL chain: acceptance → drain →
# assistant turn + conversation_reply invocation → real admission → the
# real start/build/dispatch path against the fake adapter → terminal apply
# → the reply converger settling the timeline. Only the HTTP adapter is
# faked (the harness's charter — hand-built rows are how bugs hide).
class Conversations::ReplyLaneTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper
  include LogCapture

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    # Answered by the agent: the engine of every reply head here is the agent's.
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  def accept!(kind: "message", text: "hello", provider: nil, model: nil, **overrides)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
      host: @conversation, acting_user: @human, kind: kind,
      role: "user", entries: text ? [{ "text" => text }] : [],
      visible_in_context: true, delivery_mode: "queue", context_mode: nil, context_options: nil,
      expected_context_revision: nil, expected_tail_turn_public_id: nil,
      provider_id: provider, model_ref: model, reasoning_effort: nil,
      request_options: nil,
    }.merge(overrides)))
    assert_predicate result, :accepted?
    result.value
  end

  def drain! = Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)

  def admitted_reply_attempt
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.conversation_id == @conversation.id
    end
    raise "reply not admitted" if admitted.nil?

    clear_enqueued_jobs
    admitted.attempt
  end

  test "a reply runs the whole lane: context in, Mock answer out, lane released" do
    accept!(text: "materialize me first")
    accept!(kind: "direct_reply", text: "what is up",
      provider: "dev", model: "mock-text")
    drained = drain!
    assert_equal 2, drained, "the user turn and the reply both materialized"

    reply_turn = @conversation.conversation_turns.order(:position).last
    assert_equal "direct_reply", reply_turn.kind
    assert_equal "assistant", reply_turn.role
    assert_equal "running", reply_turn.status
    assert_equal reply_turn.id, @conversation.reload.active_turn_id, "the lane is busy"

    invocation = @conversation.model_invocations.sole
    assert_equal "conversation_reply", invocation.purpose
    assert_equal "queued", invocation.status
    assert_equal "interactive", invocation.service_class

    request = invocation.content_bodies.find_by!(role: "request")
    entries = request.content_body_entries.map { |e| e.content_fragment.payload }
    assert_equal 1, entries.length,
      "the user turn and the user prompt are ADJACENT SAME-ROLE — merged for the wire"
    assert entries.all? { |payload| payload.key?("role") && payload.key?("parts") }
    assert_equal ["materialize me first", "what is up"],
      entries.first.fetch("parts").map { |part| part["text"] }, "the timeline and the prompt ride one message"

    attempt = admitted_reply_attempt
    apply_via(attempt, sse_success("the reply"))
    assert_equal "completed", invocation.reload.status

    result = Conversations::Turns::Converge.call
    assert_equal 1, result.value[:recorded]

    variant = reply_turn.reload.active_variant
    assert_equal "completed", variant.status
    assert_equal "completed", reply_turn.status
    assert_includes variant.content_bodies.find_by!(role: "content").effective_text,
      "Mock: the reply"
    assert_equal invocation.content_bodies.find_by!(role: "response")
        .content_body_entries.pluck(:content_fragment_id),
      variant.content_bodies.find_by!(role: "content")
        .content_body_entries.pluck(:content_fragment_id),
      "the answer entry-copies onto the SAME fragments"
    assert_includes variant.content_preview, "Mock: the reply"

    @conversation.reload
    assert_nil @conversation.active_turn_id, "the lane released"
    assert_equal 2, @conversation.context_revision, "user turn + completed visible reply"
    assert_not_nil invocation.reload.terminal_event_recorded_at

    statuses = @conversation.conversation_event_items
      .where(item_type: "turn_status").order(:sequence).map { |i| i.payload["status"] }
    assert_equal %w[running completed], statuses,
      "the lifecycle stream tells the whole run story"
    kinds = @conversation.conversation_event_items
      .where(item_type: "turn_status").order(:sequence).map { |i| i.payload["turn_kind"] }
    assert_equal %w[direct_reply direct_reply], kinds,
      "the materializer's and the settle's item both carry the turn's kind (the follower's, 2026-09-18)"

    repeat = Conversations::Turns::Converge.call
    assert_equal 0, repeat.value[:recorded], "the marker leaves the frontier"

    # OCCUPANCY, from the receipt the run actually wrote. The singular
    # read renders this block only once a real usage record exists, which
    # is why it must be asserted HERE — at the end of the one test that
    # produces one — rather than from a hand-built row that could carry
    # fields the recorder never writes.
    context = AgentAPI::ConversationPresenter.full(@conversation.reload).fetch(:context)
    assert_equal "dev", context.dig(:as_of_model, :provider_id)
    assert_equal "mock-text", context.dig(:as_of_model, :model_ref),
      "the receipt names one catalog key; the wire splits it the way every model block is split"
    assert_equal 8192, context.fetch(:window_tokens)
    assert_operator context.fetch(:used_tokens), :>, 0
    assert_operator context.fetch(:used_percent), :>, 0

    # THE CACHE READ: the provider's own count of prefix bytes it served from cache, off the same
    # record — absent when it reported none, never a local count. The paid side-conversation
    # confirmation reads this one number.
    record = UsageRecord.where(id: Conversations::Compaction::LastUsage.for_conversation(@conversation).record.id)
    record.update_all(cache_read_tokens: nil)
    assert_not AgentAPI::ConversationPresenter.full(@conversation.reload).fetch(:context).key?(:cache_read_tokens),
      "no number reported, no key"
    record.update_all(cache_read_tokens: 300)
    assert_equal 300, AgentAPI::ConversationPresenter.full(@conversation.reload).fetch(:context).fetch(:cache_read_tokens)
  end

  # Cross-model reasoning, stage 1: the provenance sidecar freezes the
  # native trace at apply and rides to the settled variant with its
  # display twin — through the REAL chain, not hand-built rows.
  test "a reasoning reply captures the provenance sidecar and clones it at convergence" do
    accept!(kind: "direct_reply", text: "think about it",
      provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt, sse_success("done", reasoning: "step one, step two"))
    invocation = @conversation.model_invocations.sole

    display = invocation.content_bodies.find_by!(role: "reasoning")
    assert_equal "step one, step two", display.effective_text,
      "the display body stays the joined text the read surfaces serve"

    trace = invocation.content_bodies.find_by!(role: "reasoning_trace")
    envelope = trace.content_body_entries.sole.content_fragment.payload
    assert_equal "nexus.reasoning_trace.v1", envelope["format"]
    assert_equal "dev", envelope["origin_provider_id"]
    assert_equal "responses_reasoning", envelope["origin_format_variant"],
      "the dev lane speaks responses — format follows the WIRE, not the provider"
    assert_equal invocation.public_id, envelope["origin_invocation_id"]
    item = ModelReasoning::Trace.new(envelope: envelope).reasoning_items.sole
    assert_equal "step one, step two", item["summary_text"]
    assert_equal "r1", item["item_id"]
    assert_equal ["assistant_message"], ModelReasoning::Trace.new(envelope: envelope).markers.map { |m| m["kind"] },
      "the answer's message holds its place beside the reasoning"

    Conversations::Turns::Converge.call
    variant = @conversation.conversation_turns.sole.reload.active_variant
    cloned = variant.content_bodies.find_by!(role: "reasoning_trace")
    assert_equal trace.content_body_entries.pluck(:content_fragment_id),
      cloned.content_body_entries.pluck(:content_fragment_id),
      "the sidecar entry-copies onto the SAME fragments — zero bytes"
  end

  # Cross-model reasoning, stage 2: same-model native replay through the
  # REAL chain — the captured encrypted trace re-inserts as a role-less
  # reasoning item in the NEXT reply's sealed request.
  test "the next reply replays the prior turn's encrypted reasoning natively" do
    accept!(kind: "direct_reply", text: "first ask", provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt,
      sse_success("one", reasoning: "planned it", reasoning_encrypted: "gAAA-blob"))
    Conversations::Turns::Converge.call

    accept!(kind: "direct_reply", text: "second ask", provider: "dev", model: "mock-text")
    drain!

    invocation = @conversation.model_invocations.order(:id).last
    entries = invocation.content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
    item = entries.find { |payload| payload["type"] == "reasoning_item" }
    assert_not_nil item, "the native item rides the sealed request — the audit truth IS the wire"
    assert_equal "gAAA-blob", item.dig("payload", "encrypted_content")
    assert_equal "planned it", item.dig("payload", "summary", 0, "text")
    item_index = entries.index(item)
    assistant_index = entries.index { |p| p["role"] == "assistant" }
    assert_operator item_index, :<, assistant_index,
      "the Responses shape: the item precedes the message it produced"
  end

  # A plain reply's answer rides the next request with the label its wire
  # gave it and the lane that licenses it — nothing replayable was thought,
  # and the label is the round's own fact, not replay material, so a
  # conversation that silenced replay still sends it.
  test "the next reply resends the prior turn's assistant phase on the same lane, whatever the replay mode" do
    accept!(kind: "direct_reply", text: "first ask", provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt, sse_success("one", phase: "final_answer"))
    Conversations::Turns::Converge.call

    accept!(kind: "direct_reply", text: "second ask", provider: "dev", model: "mock-text")
    drain!
    attempt = admitted_reply_attempt
    answer = sealed_request_entries(attempt.model_invocation).find { |payload| payload["role"] == "assistant" }
    assert_equal "final_answer", answer["phase"]
    assert_equal %w[dev openai_responses], answer.fetch("native_origin").values_at("provider_id", "api_format")
    wire = JSON.parse(build(attempt).request.payload).fetch("input").find { |item| item["role"] == "assistant" }
    assert_equal "final_answer", wire["phase"], "the same lane receives the label"
    apply_via(attempt, sse_success("two"))
    Conversations::Turns::Converge.call

    accept!(kind: "direct_reply", text: "third ask", provider: "dev", model: "mock-text",
      context_options: { "reasoning_replay" => { "mode" => "none" } })
    drain!
    silenced = @conversation.model_invocations.order(:id).last
    answers = sealed_request_entries(silenced).select { |payload| payload["role"] == "assistant" }
    assert_equal ["final_answer", nil], answers.map { |payload| payload["phase"] },
      "replay silenced, the label still rides — and an unlabelled answer carries none"
    assert_not answers.last.key?("native_origin"), "an origin rides only beside a phase"
  end

  test "an unstorable trace drops the sidecar and keeps the billed answer" do
    accept!(kind: "direct_reply", text: "big think", provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt,
      sse_success("done", reasoning: "s", reasoning_encrypted: "x" * 1_100_000))

    invocation = @conversation.model_invocations.sole
    assert_equal "completed", invocation.reload.status,
      "the optional sidecar must never destroy the primary deliverable"
    assert_nil invocation.content_bodies.find_by(role: "reasoning_trace")
    assert_not_nil invocation.content_bodies.find_by(role: "response")
  end

  # A replay the window cannot carry is history the window cannot carry: the head arms the summary,
  # and no request is re-sent without the traces.
  test "a replay the window cannot carry arms the summary instead of dropping itself" do
    accept!(kind: "direct_reply", text: "first", provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt,
      sse_success("ok", reasoning: "a long plan", reasoning_encrypted: "blob-long",
        usage: { "input_tokens" => 2, "output_tokens" => 3, "output_tokens_details" => { "reasoning_tokens" => 9_000 } }))
    Conversations::Turns::Converge.call

    head = accept!(kind: "direct_reply", text: "second ask", provider: "dev", model: "mock-text")
    lines = capture_log { drain! }

    assert_equal "running", @conversation.conversation_turns.find_by!(kind: "compaction_summary").status
    assert_equal "pending", head.reload.state, "the head waits behind the summary"
    assert_empty lines.grep(/event=reasoning_replay_dropped/)
    assert_equal 1, @conversation.model_invocations.count, "nothing was sent without the traces"
  end

  # Inline is the client's own text: lead then tail, behind history and ahead of the prompt —
  # funded like the prompt, never yielded to the budget.
  test "inline text rides at its stated position" do
    accept!(text: "some history")
    drain!
    accept!(kind: "direct_reply", text: "the ask", provider: "dev", model: "mock-text",
      context_options: { "inline" => [
        { "role" => "developer", "text" => "you are terse" },
        { "role" => "user", "text" => "context note", "position" => "tail" },
      ] })
    drain!

    invocation = @conversation.model_invocations.sole
    entries = invocation.content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
    assert_equal %w[user developer user], entries.map { |payload| payload["role"] }
    assert_equal "some history", entries.first.dig("parts", 0, "text"), "history leads"
    assert_equal "you are terse", entries.second.dig("parts", 0, "text"), "the lead rides behind history"
    assert_equal ["context note", "the ask"], entries.last.fetch("parts").map { |part| part["text"] },
      "the tail note and the prompt merge in order on the same role, each its own part"
  end

  # The replay policy knob: none silences, all replays every traced turn.
  test "the reasoning_replay mode governs what rides" do
    accept!(kind: "direct_reply", text: "one", provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt,
      sse_success("a", reasoning: "r1", reasoning_encrypted: "blob-1"))
    Conversations::Turns::Converge.call

    accept!(text: "a message between")
    drain!

    accept!(kind: "direct_reply", text: "two", provider: "dev", model: "mock-text",
      context_options: { "reasoning_replay" => { "mode" => "none" } })
    drain!
    silenced = @conversation.model_invocations.order(:id).last
    entries = silenced.content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
    assert_nil entries.find { |p| p["type"] == "reasoning_item" }, "none silences replay"
    apply_via(admitted_reply_attempt,
      sse_success("b", reasoning: "r2", reasoning_encrypted: "blob-2"))
    Conversations::Turns::Converge.call

    accept!(kind: "direct_reply", text: "three", provider: "dev", model: "mock-text",
      context_options: { "reasoning_replay" => { "mode" => "all" } })
    drain!
    all_mode = @conversation.model_invocations.order(:id).last
    items = all_mode.content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
      .select { |p| p["type"] == "reasoning_item" }
    assert_equal %w[blob-1 blob-2],
      items.map { |i| i.dig("payload", "encrypted_content") },
      "all replays every traced turn, oldest first (separated turns; " \
      "MERGED adjacent assistants keep only the newest item — the wire " \
      "pairs one item with the message it precedes)"
  end

  test "the estimate models the same replay the send will carry" do
    accept!(kind: "direct_reply", text: "one", provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt,
      sse_success("a", reasoning: "a substantial plan summary " * 20,
        reasoning_encrypted: "blob"))
    Conversations::Turns::Converge.call

    estimate = ->(mode) do
      Conversations::ContextEstimate.call(Conversations::ContextEstimate::Command.new(
        conversation: @conversation.reload, acting_user: @human, provider_id: "dev",
        model_ref: "mock-text", reasoning_effort: nil, request_options: nil, prompt: "next",
        history_max_entries: nil, history_token_budget_share: nil,
        reasoning_replay_mode: mode, inline: nil
      )).value
    end

    assert_operator estimate.call(nil).input_tokens, :>, estimate.call("none").input_tokens,
      "the default estimate counts the replayed summary; mode none counts less"

    @conversation.update!(reasoning_replay_downgraded_at: Time.current)
    assert_equal estimate.call(nil).input_tokens, estimate.call("none").input_tokens,
      "the kill-switch silences the estimate's default exactly like the send's"
  end

  # A WINDOW OVERFLOW IS COMPACTION'S, NEVER A TRACE CUT: the kill-switch is a shape-fault switch —
  # a provider's 4xx on the native material itself — and a length refusal of a replay-bearing
  # request arms the between-turn summary instead, the reply staying a failed sample and the next
  # head draining behind the summary.
  test "a length refusal of a replay-bearing request arms the summary and leaves the kill-switch alone" do
    accept!(kind: "direct_reply", text: "one", provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt,
      sse_success("a", reasoning: "r1", reasoning_encrypted: "blob-1"))
    Conversations::Turns::Converge.call

    accept!(kind: "direct_reply", text: "two", provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt, json_response(400, {
      "error" => { "message" => "prompt is too long: 213462 tokens > 200000 maximum" },
    }))
    Conversations::Turns::Converge.call

    invocation = @conversation.model_invocations.order(:id).last
    assert_equal "provider_context_overflow", invocation.failure_reason_key,
      "the fixture must actually take the overflow classification, or this proves nothing"
    assert_nil @conversation.reload.reasoning_replay_downgraded_at, "an overflow never cuts the traces"
    summary = @conversation.conversation_turns.find_by!(kind: "compaction_summary")
    assert_equal "running", summary.status, "the overflow arms the between-turn summary"
    assert_equal "overflow", @conversation.conversation_event_items.where(item_type: "context_compacted")
      .sole.payload["trigger"]
  end

  test "a provider refusal of a replay-bearing request trips the kill-switch" do
    accept!(kind: "direct_reply", text: "one", provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt,
      sse_success("a", reasoning: "r1", reasoning_encrypted: "blob-1"))
    Conversations::Turns::Converge.call

    accept!(kind: "direct_reply", text: "two", provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt,
      json_response(400, { error: { message: "invalid reasoning item" } }))
    Conversations::Turns::Converge.call

    assert_not_nil @conversation.reload.reasoning_replay_downgraded_at,
      "a 4xx on a replay-bearing request stamps the downgrade"
    assert @conversation.conversation_event_items
      .exists?(item_type: "reasoning_replay_downgraded"), "the downgrade narrates"

    accept!(kind: "direct_reply", text: "three", provider: "dev", model: "mock-text")
    drain!
    downgraded = @conversation.model_invocations.order(:id).last
    entries = downgraded.content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
    assert_nil entries.find { |p| p["type"] == "reasoning_item" },
      "the default stays silenced for this conversation"
    apply_via(admitted_reply_attempt, sse_success("c"))
    Conversations::Turns::Converge.call

    accept!(kind: "direct_reply", text: "four", provider: "dev", model: "mock-text",
      context_options: { "reasoning_replay" => { "mode" => "last_turn" } })
    drain!
    explicit = @conversation.model_invocations.order(:id).last
    entries = explicit.content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
    assert entries.any? { |p| p["type"] == "reasoning_item" },
      "an explicit caller mode wins over the downgrade — re-enabling is one intent away"
  end

  test "after a model switch the earlier reasoning carries nothing: no foreign blob, no fence" do
    accept!(kind: "direct_reply", text: "first ask", provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt,
      sse_success("one", reasoning: "the plan", reasoning_encrypted: "gAAA-blob"))
    Conversations::Turns::Converge.call

    accept!(kind: "direct_reply", text: "second ask", provider: "dev", model: "mock-priced")
    drain!

    invocation = @conversation.model_invocations.order(:id).last
    entries = invocation.content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
    assert_nil entries.find { |p| p["type"] == "reasoning_item" },
      "an encrypted blob never crosses a model boundary"
    assistant = entries.find { |p| p["role"] == "assistant" }
    assert_equal [{ "type" => "text", "text" => "Mock: one" }], assistant.fetch("parts"),
      "the answer rides as it was; its thinking reads as nothing on the other model"
    assert_not_includes entries.to_json, "the plan"
  end

  # The per-request history intent: the caller speaks in bounds — entries up, or a share of the
  # model's own window — and the kernel's assembler honors them at materialization.
  test "history max_entries bounds the compiled context to the newest turns" do
    accept!(text: "older history that must fall off")
    accept!(text: "newest history")
    drain!
    accept!(kind: "direct_reply", text: "what is up",
      provider: "dev", model: "mock-text",
      context_options: { "history" => { "max_entries" => 1 } })

    drain!

    request = @conversation.model_invocations.sole.content_bodies.find_by!(role: "request")
    entries = request.content_body_entries.map { |e| e.content_fragment.payload }
    texts = entries.flat_map { |p| Array(p["parts"]).map { |part| part["text"] } }.join("\n")
    assert_includes texts, "newest history", "selection walks newest-first"
    assert_includes texts, "what is up"
    assert_not_includes texts, "older history", "the bound cut exactly the oldest"
  end

  test "a tiny token budget share drops history but never the prompt" do
    accept!(text: SecureRandom.hex(500))
    drain!
    accept!(kind: "direct_reply", text: "just this",
      provider: "dev", model: "mock-text",
      context_options: { "history" => { "token_budget_share" => 0.001 } })

    drain!

    request = @conversation.model_invocations.sole.content_bodies.find_by!(role: "request")
    entries = request.content_body_entries.map { |e| e.content_fragment.payload }
    assert_equal 1, entries.length, "history spent past its share; the prompt stands alone"
    assert_equal "just this", entries.first.dig("parts", 0, "text")
  end

  # THE FIT IS THE WALL (cache audit 2026-09-16, prefix-4): with no stated
  # intent the assembly fits history to the model's window — and an
  # overflow of that fit arms the timeline compaction, the one licensed
  # cache bust with a stable head after it, instead of sending a request
  # that drops the oldest turn on every reply: a sliding window re-writes
  # the whole history at cache-write rates with no read on it, on every
  # turn. Codex and claude-code compact; they never slide. The prompt
  # never yields; the head waits behind the summary and drains again.
  test "oversized history arms the summary turn instead of sliding the window" do
    accept!(text: SecureRandom.hex(20_000))
    drain!
    accept!(kind: "direct_reply", text: "summarize", provider: "dev", model: "mock-text")

    drain!

    summary = @conversation.conversation_turns.find_by!(kind: "compaction_summary")
    assert_equal "running", summary.status
    assert_equal "pending", @conversation.conversation_inputs.sole.state,
      "the head waits behind the summary and drains again"
    assert_equal 0, ModelInvocation.count, "no trimmed request was sent"
    assert_empty @conversation.conversation_event_items.where(item_type: "context_trimmed"),
      "nothing slid: the summary IS the cut"
    assert_equal 1, AgentLoop.count
    assert_equal "compaction_summary", AgentLoop.sole.conversation_turn.kind
  end

  test "a prompt the model cannot take blocks before a coin is spent" do
    accept!(kind: "direct_reply", text: SecureRandom.hex(20_000),
      provider: "dev", model: "mock-text")

    drain!

    blocked = @conversation.conversation_inputs.sole
    assert_equal "blocked", blocked.state
    assert_equal "estimated_input_exceeds_model_limit", blocked.blocked_reason,
      "history yields to the window; the prompt itself never can — only IT still blocks"
    assert_equal 0, ModelInvocation.count, "nothing was sent, nothing was billed"
  end

  # The compile-vs-raw split: raw is the advanced escape hatch — the
  # caller's prompt goes verbatim, no history, no merging, no enrichment.
  test "raw mode sends the caller's prompt verbatim, ignoring the timeline" do
    accept!(text: "history that must NOT ride")
    drain!
    accept!(kind: "direct_reply", context_mode: "raw",
      provider: "dev", model: "mock-text",
      entries: [{ "role" => "user",
                  "parts" => [{ "type" => "text", "text" => "raw question" }] }])

    drain!

    invocation = @conversation.model_invocations.sole
    entries = invocation.content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
    assert_equal 1, entries.length, "exactly what the caller sent"
    assert_equal "raw question", entries.first.dig("parts", 0, "text")
  end

  test "a malformed raw prompt blocks with the grammar's refusal" do
    accept!(kind: "direct_reply", context_mode: "raw",
      provider: "dev", model: "mock-text",
      entries: [{ "text" => "bare" },
                { "role" => "user",
                  "parts" => [{ "type" => "text", "text" => "mixed" }] }])

    assert_equal 0, drain!
    assert_equal "invalid_input", @conversation.conversation_inputs.sole.blocked_reason
  end

  test "an unresolvable selection parks the head as blocked, narrated, FIFO held" do
    accept!(kind: "direct_reply", text: "reply please",
      provider: "dev", model: "no-such-model")
    accept!(text: "queued behind")

    assert_equal 0, drain!

    blocked = @conversation.conversation_inputs.order(:queue_position).first
    assert_equal "blocked", blocked.state
    assert_equal "unknown_model", blocked.blocked_reason
    assert_equal 2, @conversation.conversation_inputs.count, "nothing skipped, nothing lost"
    assert_equal 0, @conversation.conversation_turns.count

    narration = @conversation.conversation_event_items.where(item_type: "input_blocked").sole
    assert_equal "unknown_model", narration.payload["blocked_reason"]
  end

  test "a failed reply converges as failure: turn settled, lane released, narrated" do
    accept!(kind: "direct_reply", text: "doomed", provider: "dev", model: "mock-text")
    drain!
    attempt = admitted_reply_attempt
    apply_via(attempt, json_response(400, { error: { message: "bad request" } }))

    invocation = @conversation.model_invocations.sole
    assert_equal "failed", invocation.reload.status

    assert_equal 1, Conversations::Turns::Converge.call.value[:recorded]

    turn = @conversation.conversation_turns.sole.reload
    assert_equal "failed", turn.status
    assert_equal "failed", turn.active_variant.status
    assert_nil @conversation.reload.active_turn_id, "a failure releases the lane too"
    assert_equal 0, @conversation.context_revision,
      "a failed reply is not context; nothing here ever bumped the revision"

    status_item = @conversation.conversation_event_items
      .where(item_type: "turn_status").order(:sequence).last
    assert_equal "failed", status_item.payload["status"]
  end

  test "a vanished variant is tolerated: the marker stamps, nothing applies" do
    accept!(kind: "direct_reply", text: "orphan me", provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt, sse_success("late"))
    invocation = @conversation.model_invocations.sole
    ConversationTurnVariant.where(model_invocation_id: invocation.id)
      .update_all(model_invocation_id: nil)

    result = Conversations::Turns::Converge.call

    assert_equal 1, result.value[:recorded]
    assert_not_nil invocation.reload.terminal_event_recorded_at,
      "the frontier releases the row even with nothing to apply to"
  end

  test "a conversation with settled reply history reaps clean through the FK" do
    accept!(text: "hi")
    accept!(kind: "direct_reply", text: "answer me",
      provider: "dev", model: "mock-text")
    drain!
    apply_via(admitted_reply_attempt, sse_success("done"))
    Conversations::Turns::Converge.call

    Conversations::Tombstone.call(conversation: @conversation.reload)
    Conversation.where(id: @conversation.id)
      .update_all(tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago)

    result = Conversations::Reap.call(batch: 10)

    assert_equal 1, result.value[:reaped]
    assert_not Conversation.exists?(@conversation.id)
    assert_equal 0, ModelInvocation.where.not(conversation_id: nil).count,
      "the invocation drain ran leaves-first; the FK never fired"
    assert UsageRecord.exists?, "usage receipts are value-linked and survive"
  end

  # ── The loop-backed lane ───────────────────────────────────── A tool-bearing agent's reply is a
  # kernel loop born running; round one is minted by the scheduler from the entries body
  # materialization sealed, and the converger settles the turn from the loop's deliverable.

  def loop_reply!(text: "what is up")
    declare_tools!(@agent)
    accept!(text: "materialize me first")
    materialize_loop_reply!(@conversation, agent: @agent, text: text)
  end

  def turn_status_items
    @conversation.conversation_event_items.where(item_type: "turn_status")
      .order(:sequence).map(&:payload)
  end

  test "a tool-bearing agent's reply runs the whole lane: loop, round one, settle" do
    reply_turn, agent_loop = loop_reply!
    assert_equal "running", agent_loop.status
    assert_empty @conversation.model_invocations,
      "no invocation at materialization: round one is the scheduler's mint"

    schedule_loop!(agent_loop)
    r1 = agent_loop.agent_loop_nodes.find_by!(node_key: "r1")
    assert_equal "running", r1.status
    invocation = ModelInvocation.find(r1.selected_model_invocation_id)
    assert_equal "agent_loop_step", invocation.purpose
    entries = round_request_entries(r1)
    assert_equal 1, entries.length
    assert_equal ["materialize me first", "what is up"], entries.first.fetch("parts").map { |part| part["text"] },
      "the entries body rides as the message list, never as one JSON prompt"
    assert_equal [READ_TOOL], r1.tool_definitions, "the stored declaration keeps its original schema"
    wire_tool = READ_TOOL.deep_merge("function" => { "strict" => false })
    assert_equal [wire_tool], invocation.request_options.fetch("tools"),
      "the provider projection defaults to non-strict arguments"
    assert_not invocation.request_options.key?("instructions"),
      "round one carries no instructions: the system channel is the list"

    run_loop_round!(agent_loop, sse_success("the reply"))
    assert_equal "completed", r1.reload.status
    assert_equal "completed", agent_loop.reload.status
    assert_equal "running", reply_turn.reload.status, "the loop lock never writes the turn"

    assert_equal 1, Conversations::Turns::Converge.call.value[:recorded]
    variant = reply_turn.reload.active_variant
    assert_equal "completed", variant.status
    assert_equal "completed", reply_turn.status
    assert_equal "Mock: the reply",
      variant.content_bodies.find_by!(role: "content").effective_text,
      "the settle copies the deliverable's output onto the variant"
    @conversation.reload
    assert_nil @conversation.active_turn_id, "the lane released"
    assert_equal 2, @conversation.context_revision

    items = turn_status_items
    assert_equal %w[running completed],
      items.filter_map { |payload| payload["status"] }
    assert items.all? { |payload| payload["agent_loop_public_id"] == agent_loop.public_id },
      "every turn_status item names the loop behind the turn"
    assert_equal %w[direct_reply], items.map { |payload| payload["turn_kind"] }.uniq,
      "and the turn's kind — the materializer's, the loop's and the settle's item alike"
  end

  test "a tool round expands a fan and a continuation, and the settle waits" do
    reply_turn, agent_loop = loop_reply!
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("calling", tool_calls: [
      { id: "call_a", name: "read_file", arguments: "{\"path\":\"a\"}" },
    ]))

    fan = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_a")
    assert_equal "dispatched", fan.status, "the fan parks on its runner"
    continuation = agent_loop.agent_loop_nodes.where(continuation_source: "round")
      .where.not(node_key: "r1").sole
    assert_equal "queued", continuation.status
    assert_equal [READ_TOOL], continuation.tool_definitions
    assert_equal continuation.id, agent_loop.reload.deliverable_node_id
    assert_equal "running", agent_loop.status

    assert_equal 0, Conversations::Turns::Converge.call.value[:recorded], "nothing to settle yet"
    assert_equal "running", reply_turn.reload.status
    assert_equal reply_turn.id, @conversation.reload.active_turn_id
  end

  test "a steer typed while round one is queued lands in its sealed request" do
    reply_turn, agent_loop = loop_reply!
    steer = accept!(text: "briefly, please", delivery_mode: "steer")
    assert_equal "steering", steer.state
    assert_equal reply_turn.id, steer.steering_target_turn_id

    schedule_loop!(agent_loop)

    r1 = agent_loop.agent_loop_nodes.find_by!(node_key: "r1")
    entries = round_request_entries(r1)
    assert_equal "briefly, please", entries.last.dig("parts", 0, "text"),
      "the directive drains into round one as its own final user message"
    assert_not ConversationInput.exists?(steer.id), "the words landed"
  end
end
