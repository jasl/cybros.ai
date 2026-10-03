require "test_helper"
require "test_helpers/invocation_result_test_helper"

# The tail content verbs through the REAL chain: regenerate re-asks the
# same sealed request as a sibling (byte-shared), a completed sample takes
# the pointer, a failed one leaves the settled turn standing; edit becomes
# a new activated candidate on either kind; activate is the swipe switch.
class Conversations::TailVerbsTest < ActiveJob::TestCase
  include InvocationResultTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  def accept!(kind: "message", text: "hello", **overrides)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
      host: @conversation, acting_user: @human, kind: kind,
      role: "user", entries: [{ "text" => text }], visible_in_context: true,
      delivery_mode: "queue", context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
    assert_predicate result, :accepted?
    result.value
  end

  def drain! = Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)

  def settled_reply!(answer: "first answer", provider_id: "dev", model_ref: "mock-text", **overrides)
    accept!(kind: "direct_reply", text: "the prompt",
      provider_id: provider_id, model_ref: model_ref, **overrides)
    drain!
    apply_via(admitted_attempt_for(@conversation), sse_success(answer))
    Conversations::Turns::Converge.call
    @conversation.conversation_turns.order(:position).last.reload
  end

  def admitted_attempt_for(conversation)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.conversation_id == conversation.id
    end
    raise "not admitted" if admitted.nil?

    clear_enqueued_jobs
    admitted.attempt
  end

  def regenerate!(turn, **overrides)
    Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(**{
      conversation: @conversation, turn_public_id: turn.public_id,
      acting_user: @human, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
  end

  test "regenerate re-asks the same bytes; the completed sample takes the pointer" do
    turn = settled_reply!
    original = turn.active_variant
    original_request = original.model_invocation.content_bodies.find_by!(role: "request")

    result = regenerate!(turn)

    assert_predicate result, :accepted?
    assert_equal "running", turn.reload.status, "the reopen: the one deliberate exception"
    assert_equal original.id, turn.active_variant_id, "the old candidate keeps rendering"
    new_variant = result.value
    assert_equal original.id, new_variant.origin_variant_id

    new_request = new_variant.reload.model_invocation.content_bodies.find_by!(role: "request")
    assert_equal original_request.content_body_entries.pluck(:content_fragment_id),
      new_request.content_body_entries.pluck(:content_fragment_id),
      "the SAME request, entry-copied — zero bytes"

    apply_via(admitted_attempt_for(@conversation), sse_success("second answer"))
    Conversations::Turns::Converge.call

    turn.reload
    assert_equal "completed", turn.status
    assert_equal new_variant.id, turn.active_variant_id, "the completed sample takes over"
    assert_includes turn.active_variant.content_preview, "Mock: second answer"
    assert_equal 2, turn.conversation_turn_variants.live.count, "the original stays in the deck"
  end

  # History is exactly once in every template, so a regenerate under `assembly` — which passes no
  # prompt and rides the question on history — still re-asks the question, behind the template's own
  # text.
  test "regenerate under an assembly template carries the question and the template's order" do
    agent = users(:agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent)
    template = { "blocks" => [
      { "type" => "inline", "role" => "developer", "text" => "Answer as {{agent}}." },
      { "type" => "history" }, { "type" => "input" },
    ] }
    outcome = Users::DeclareConfiguration.call(user: agent, tool_definitions: [], approval_mode: nil, approval_rules: nil,
      prompt_mechanism: "assembly", prompt_template: template, compaction_policy: nil)
    assert_equal :declared, outcome.outcome
    turn = settled_reply!

    result = regenerate!(turn)
    assert_predicate result, :accepted?, result.outcome.inspect
    request = result.value.reload.model_invocation.content_bodies.find_by!(role: "request")
    entries = request.content_body_entries.map { |entry| entry.content_fragment.payload }
    assert_equal %w[developer user], entries.map { |entry| entry["role"] }
    assert_equal "Answer as Fixture Agent.", entries[0].dig("parts", 0, "text")
    assert_equal "the prompt", entries[1].dig("parts", 0, "text"), "the question rides history"
  end

  test "a failed regeneration leaves the settled turn exactly as it stood" do
    turn = settled_reply!
    original = turn.active_variant

    regenerate!(turn)
    apply_via(admitted_attempt_for(@conversation),
      json_response(400, { error: { message: "no" } }))
    Conversations::Turns::Converge.call

    turn.reload
    assert_equal "completed", turn.status, "the failed sample never drags the turn down"
    assert_equal original.id, turn.active_variant_id
    assert_equal "failed",
      turn.conversation_turn_variants.order(:position).last.status,
      "the failed candidate just sits in the deck"
    assert_nil @conversation.reload.active_turn_id
  end

  # A declined sample is a failed one: the call completed, the reply did
  # not. It never takes the pointer from a completed sample, and one
  # `turn_status` says so — the sample failed, why, and the category.
  test "a refused regeneration never replaces the completed answer" do
    turn = settled_reply!
    original = turn.active_variant
    revision = @conversation.reload.context_revision

    regenerate!(turn)
    apply_via(admitted_attempt_for(@conversation), sse_refused("I can't help with that.", text: "Sure"))
    Conversations::Turns::Converge.call

    turn.reload
    assert_equal ["completed", original.id], [turn.status, turn.active_variant_id]
    refused = turn.conversation_turn_variants.order(:position).last
    assert_equal "failed", refused.status
    assert_nil refused.content_bodies.find_by(role: "content"), "a declined answer leaves nothing to adopt"
    assert_equal revision, @conversation.reload.context_revision, "only a real completion moves the context"
    item = @conversation.conversation_event_items.where(item_type: "turn_status").order(:sequence).last.payload
    assert_equal ["completed", "failed", "model_refused", "refused"],
      item.values_at("status", "variant_status", "failure_reason_key", "finish_quality")
  end

  test "a refused direct reply fails its turn, naming the refusal and its category" do
    accept!(kind: "direct_reply", text: "the prompt", provider_id: "dev", model_ref: "mock-text")
    drain!
    turn = @conversation.conversation_turns.order(:position).last
    refused = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "secret",
      adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
        "id" => "msg_1", "content" => [], "stop_reason" => "refusal",
        "stop_details" => { "category" => "cyber", "explanation" => "no" },
        "usage" => { "input_tokens" => 2, "output_tokens" => 0 },
      }))
    ).create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)
    apply_provider_result(admitted_attempt_for(@conversation), refused, adapter_profile: "anthropic_messages")

    Conversations::Turns::Converge.call

    assert_equal "failed", turn.reload.status
    assert_equal "failed", turn.active_variant.status
    assert_nil @conversation.reload.active_turn_id, "the lane is idle again"
    items = @conversation.conversation_event_items.where(item_type: "turn_status").order(:sequence).map(&:payload)
      .select { |payload| payload["turn_public_id"] == turn.public_id && payload.key?("failure_reason_key") }
    assert_equal [{ "turn_public_id" => turn.public_id, "turn_kind" => turn.kind,
                    "variant_public_id" => turn.active_variant.public_id, "status" => "failed",
                    "variant_status" => "failed", "failure_reason_key" => "model_refused",
                    "finish_quality" => "refused", "refusal_category" => "cyber" }], items
  end

  test "regenerate refuses off the tail, on messages, and mid-run" do
    turn = settled_reply!
    accept!(text: "a message after")
    drain!

    assert_equal :branch_required, regenerate!(turn.reload).outcome

    message_turn = @conversation.conversation_turns.order(:position).last
    assert_equal :unsupported_turn_type, regenerate!(message_turn).outcome
  end

  test "a second regenerate mid-run answers busy" do
    turn = settled_reply!
    assert_predicate regenerate!(turn), :accepted?

    assert_equal :conversation_busy, regenerate!(turn.reload).outcome
  end

  test "the fallback re-asks BELOW the turn — never a continuation of its own answer" do
    accept!(text: "the actual question")
    drain!
    turn = settled_reply!
    Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id,
      entries: [{ "text" => "hand-edited answer" }], acting_user: @human
    ))

    result = regenerate!(turn.reload)

    assert_predicate result, :accepted?,
      "a bare regenerate works after edit — the trio rode onto the edit variant"
    request = result.value.reload.model_invocation.content_bodies.find_by!(role: "request")
    entries = request.content_body_entries.map { |e| e.content_fragment.payload }
    assert_equal "user", entries.last["role"],
      "the re-ask ends with the asker, never the old answer"
    texts = entries.flat_map { |p| Array(p["parts"]).map { |part| part["text"] } }
    assert_not_includes texts.join, "hand-edited answer",
      "the turn's own answer never rides its regeneration"
  end

  def request_texts(variant)
    request = variant.reload.model_invocation.content_bodies.find_by!(role: "request")
    request.content_body_entries.map { |e| e.content_fragment.payload }
      .flat_map { |p| Array(p["parts"]).map { |part| part["text"] } }.join("\n")
  end

  # The regeneration's rule is the drain's: the CONVERSATION's answerer declares, never the
  # re-asking caller.
  test "regenerate declares through the conversation's answerer, not the re-asking agent" do
    agent = users(:agent)
    written = PromptDocuments::Write.call(anchor: { user: agent }, slot: "system_prompt",
      content: "I am the agent.", role: nil)
    assert_predicate written, :written?, written.outcome.inspect
    turn = settled_reply!

    result = regenerate!(turn, acting_user: agent)
    assert_predicate result, :accepted?
    assert_not_includes request_texts(result.value), "I am the agent.",
      "a Human-answered conversation compiles no system_prompt, whoever re-asks"

    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent)
    turn = settled_reply!
    result = regenerate!(turn)
    assert_predicate result, :accepted?
    assert_includes request_texts(result.value), "I am the agent.",
      "the answerer's system_prompt leads the Human's regeneration"
  end

  test "a tripped kill-switch makes even the same-model regenerate reassemble replay-free" do
    accept!(kind: "direct_reply", text: "warmup", provider_id: "dev", model_ref: "mock-text")
    drain!
    apply_via(admitted_attempt_for(@conversation),
      sse_success("one", reasoning: "plan", reasoning_encrypted: "blob-x"))
    Conversations::Turns::Converge.call
    turn = settled_reply!(answer: "two")
    origin_entries = turn.active_variant.model_invocation
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
    assert origin_entries.any? { |p| p["type"] == "reasoning_item" }
    @conversation.reload.update!(reasoning_replay_downgraded_at: Time.current)

    result = regenerate!(turn)

    assert_predicate result, :accepted?
    entries = result.value.reload.model_invocation
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
    assert_nil entries.find { |p| p["type"] == "reasoning_item" },
      "re-cloning what the provider refused would re-fail the turn being rescued"
  end

  test "a cross-model regenerate reassembles — a sealed native blob never rides to a foreign model" do
    accept!(kind: "direct_reply", text: "warmup", provider_id: "dev", model_ref: "mock-text")
    drain!
    apply_via(admitted_attempt_for(@conversation),
      sse_success("one", reasoning: "the plan", reasoning_encrypted: "gAAA-bound"))
    Conversations::Turns::Converge.call

    turn = settled_reply!(answer: "two")
    origin_request = turn.active_variant.model_invocation
      .content_bodies.find_by!(role: "request")
    origin_entries = origin_request.content_body_entries.map { |e| e.content_fragment.payload }
    assert origin_entries.any? { |p| p["type"] == "reasoning_item" },
      "the origin's sealed request embeds the native replay — the hazard under test"

    result = regenerate!(turn, provider_id: "dev", model_ref: "mock-priced")

    assert_predicate result, :accepted?
    request = result.value.reload.model_invocation.content_bodies.find_by!(role: "request")
    entries = request.content_body_entries.map { |e| e.content_fragment.payload }
    assert_nil entries.find { |p| p["type"] == "reasoning_item" },
      "a model override reassembles; the model-bound blob never ships to a foreign model"
    assert_not_includes entries.to_json, "the plan", "and the other model's thinking reads as nothing, not as text"
  end

  test "the fallback keeps the newest segment whatever its size, and narrates its trim" do
    accept!(text: "the older question")
    drain!
    accept!(text: SecureRandom.hex(20_000))
    drain!
    # The caller's own share: a STATED bound trims as asked, where the
    # implicit fit would arm the summary turn instead (cache audit
    # 2026-09-16, prefix-4) — this case is about the regenerate fallback.
    turn = settled_reply!(context_options: { "history" => { "token_budget_share" => 0.5 } })
    Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id,
      entries: [{ "text" => "hand-edited answer" }], acting_user: @human
    ))

    result = regenerate!(turn.reload)

    assert_predicate result, :accepted?,
      "an oversized newest segment rides on the floor — never an empty assembly"
    request = result.value.reload.model_invocation.content_bodies.find_by!(role: "request")
    texts = request.content_body_entries.map { |e| e.content_fragment.payload }
      .flat_map { |p| Array(p["parts"]).map { |part| part["text"] } }.join("\n")
    assert_not_includes texts, "the older question",
      "the budget still holds above the floor"

    trimmed = @conversation.conversation_event_items
      .where(item_type: "context_trimmed").order(:sequence).last
    assert_not_nil trimmed, "the fallback's trim is the same product fact"
    assert_operator trimmed.payload["history_skipped"], :>=, 1
  end

  test "edit becomes a new activated candidate on either kind" do
    accept!(text: "my typo'd message")
    drain!
    turn = @conversation.conversation_turns.sole

    result = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id,
      entries: [{ "text" => "my fixed message" }], acting_user: @human
    ))

    assert_predicate result, :accepted?
    turn.reload
    assert_equal "edit", turn.active_variant.source
    assert_equal "my fixed message",
      turn.active_variant.content_bodies.sole.effective_text
    assert_equal 2, turn.conversation_turn_variants.count, "the original survives in the deck"
    assert_equal 2, @conversation.reload.context_revision, "an edit is context"

    assembled = Conversations::ContextAssembly.assemble(conversation: @conversation, principal: @human)
    assert_equal "my fixed message", assembled.messages.sole.parts.sole.text,
      "assembly reads the edit"
  end

  test "activate is the swipe switch, tail-only, settled-only" do
    accept!(text: "message")
    drain!
    turn = @conversation.conversation_turns.sole
    original = turn.active_variant
    Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id,
      entries: [{ "text" => "edited" }], acting_user: @human
    ))

    activate = lambda do |variant|
      Conversations::Variants::Activate.call(Conversations::Variants::Activate::Command.new(
        conversation: @conversation, turn_public_id: turn.public_id,
        variant_public_id: variant.public_id, acting_user: @human
      ))
    end

    result = activate.call(original)
    assert_predicate result, :accepted?
    assert_equal original.id, turn.reload.active_variant_id, "swiped back"

    events_before = @conversation.conversation_event_items.count
    assert_predicate activate.call(original), :accepted?
    assert_equal events_before, @conversation.conversation_event_items.count,
      "re-activating the active candidate is an event-free no-op"

    accept!(text: "successor")
    drain!
    assert_equal :branch_required, activate.call(original).outcome,
      "the frozen prefix answers the same code everywhere"
  end

  # ── The seed rides a swipe ─────────────────────────────────

  # The seed is the TURN's question, the same for every candidate answer:
  # a sibling minted by regenerate or edit carries the origin's `prompt`
  # body, so the next turn's history still opens the turn with its words.
  test "regenerate's sibling carries the turn's prompt, and the next turn still reads the seed" do
    turn = settled_reply!
    origin = turn.active_variant
    assert_equal "the prompt", origin.content_bodies.find_by!(role: "prompt").readable_text

    result = regenerate!(turn)
    assert_predicate result, :accepted?
    sibling = result.value
    prompt = sibling.content_bodies.find_by!(role: "prompt")
    assert_equal "the prompt", prompt.readable_text
    assert_equal origin.content_bodies.find_by!(role: "prompt").content_body_entries.pluck(:content_fragment_id),
      prompt.content_body_entries.pluck(:content_fragment_id), "cloned, zero bytes"
    apply_via(admitted_attempt_for(@conversation), sse_success("second answer"))
    Conversations::Turns::Converge.call
    assert_equal sibling.id, turn.reload.active_variant_id

    segments = Conversations::ContextAssembly::ChatHistory.call(conversation: @conversation.reload).segments
    assert_equal [["user", "the prompt"], ["assistant", "Mock: second answer"]],
      segments.map { |segment| [segment.role, segment.text] }
  end

  test "edit's candidate carries the turn's prompt, and the next turn still reads the seed" do
    turn = settled_reply!
    edited = edit!(turn, "my own answer")
    assert_equal "the prompt", edited.content_bodies.find_by!(role: "prompt").readable_text

    segments = Conversations::ContextAssembly::ChatHistory.call(conversation: @conversation.reload).segments
    assert_equal [["user", "the prompt"], ["assistant", "my own answer"]],
      segments.map { |segment| [segment.role, segment.text] }
  end

  # ── The loop-backed turn ───────────────────────────────────────

  # The seam fixture settled through the converger: a completed loop is a
  # completed turn, a held one a failed turn with the person's verbs open.
  def loop_backed_settled!(loop_status: "completed", seed: false)
    seam = create_loop_backed_turn(conversation: @conversation.reload, acting_user: @human)
    # The seam fixture carries no seed; a regeneration rebuilds one, so
    # the cases that regenerate grow the origin's `r1` first.
    grow!(seam.agent_loop, model("r1", "prompt" => "go")) if seed
    if loop_status == "completed"
      AgentLoops::Transition.agent_loop(seam.agent_loop,
        status: "completed", completed_at: Time.current)
    else
      AgentLoops::Transition.agent_loop(seam.agent_loop,
        status: "needs_attention", attention_reason: "halt_failure")
    end
    Conversations::Turns::Converge.call
    seam
  end

  def edit!(turn, text)
    result = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id,
      entries: [{ "text" => text }], acting_user: @human
    ))
    assert_predicate result, :accepted?
    result.value
  end

  def activate!(turn, variant)
    Conversations::Variants::Activate.call(Conversations::Variants::Activate::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id,
      variant_public_id: variant.public_id, acting_user: @human
    ))
  end

  def verb(klass, agent_loop, key)
    klass.call(klass::Command.new(agent_loop: agent_loop, task_key: key, acting_user: @human))
  end

  # RE-CUT under C7: the `loop_backed_turn` refusal this test once pinned is lifted — a loop-backed
  # tail regenerates as a new candidate with its OWN loop; old execution evidence stays,
  # while its cancellation authority is permanently cut. The kernel judges
  # nothing about the world (the variant's `world` says what happened).
  test "regenerate on a loop-backed turn births a sibling and stops the old owner without rewriting its evidence" do
    accept!(text: "the question")
    drain!
    seam = loop_backed_settled!(seed: true)
    assert_equal "completed", seam.turn.reload.status
    origin_nodes = seam.agent_loop.agent_loop_nodes.order(:id).pluck(:id, :status)

    result = regenerate!(seam.turn, provider_id: "dev", model_ref: "mock-text")

    assert_predicate result, :accepted?, result.outcome.to_s
    sibling = result.value
    assert_equal "agent_loop", sibling.source
    assert_equal seam.variant.id, sibling.origin_variant_id
    assert_not_nil sibling.agent_loop, "its own loop"
    assert_not_equal seam.agent_loop.id, sibling.agent_loop.id
    assert_equal "running", sibling.agent_loop.status
    assert_equal ["r1"], sibling.agent_loop.agent_loop_nodes.pluck(:node_key), "the origin's seed round, rebuilt"
    assert_equal 2, seam.turn.conversation_turn_variants.count, "a deck of two"
    assert_equal seam.variant.id, seam.turn.reload.active_variant_id, "the old candidate keeps rendering"
    assert_equal "running", seam.turn.status, "the reopen"
    assert_equal seam.turn.id, @conversation.reload.active_turn_id
    assert_equal origin_nodes, seam.agent_loop.reload.agent_loop_nodes.order(:id).pluck(:id, :status),
      "the origin's loop is untouched"
    assert_equal "completed", seam.agent_loop.status
    assert_predicate seam.agent_loop, :stopped?
    assert_not sibling.agent_loop.stopped?
    assert_equal 0, ModelInvocation.where(conversation_id: @conversation.id).count,
      "the loop branch mints no invocation: round one is the scheduler's"
    assert_enqueued_with(job: AgentLoops::ScheduleJob, args: [sibling.agent_loop.id])
  end

  # A hold-settled loop is adjudicable: a sibling born beside it would leave two live loops behind
  # one turn. Refused whole.
  test "regenerate refuses loop_needs_attention while the loop awaits adjudication" do
    seam = loop_backed_settled!(loop_status: "needs_attention", seed: true)
    assert_equal "failed", seam.turn.reload.status

    result = regenerate!(seam.turn, provider_id: "dev", model_ref: "mock-text")

    assert_equal :loop_needs_attention, result.outcome
    assert_equal 1, seam.turn.conversation_turn_variants.count, "no sibling was minted"
    assert_equal "failed", seam.turn.reload.status
    assert_equal "needs_attention", seam.agent_loop.reload.status
    assert_equal 1, AgentLoop.count, "no loop was born"
  end

  test "edit and swipe are allowed on a completed loop-backed tail — a choice of what shows, no execution" do
    seam = loop_backed_settled!
    edited = edit!(seam.turn, "my own answer")
    assert_equal edited.id, seam.turn.reload.active_variant_id

    assert_predicate activate!(seam.turn, seam.variant), :accepted?
    assert_equal seam.variant.id, seam.turn.reload.active_variant_id, "swiped back to the loop's answer"
    assert_predicate activate!(seam.turn, edited), :accepted?
    assert_equal edited.id, seam.turn.reload.active_variant_id, "and forward again"
    assert_equal "completed", seam.agent_loop.reload.status, "nothing ran"
  end

  test "an edit on a hold-settled loop-backed tail stands: the loop's verbs refuse, and no reopen follows" do
    seam = loop_backed_settled!(loop_status: "needs_attention")
    assert_equal "failed", seam.turn.reload.status

    edited = edit!(seam.turn, "my own answer")
    assert_equal edited.id, seam.turn.reload.active_variant_id
    assert_equal "completed", seam.turn.status

    assert_equal :not_adjudicable, verb(AgentLoops::Tasks::Retry, seam.agent_loop, "r1").outcome
    assert_equal :not_adjudicable, verb(AgentLoops::Tasks::Abandon, seam.agent_loop, "r1").outcome
    appended = grow(seam.agent_loop, model("repair", "prompt" => "again"))
    assert_equal :not_adjudicable, appended.outcome
    assert_equal 0, seam.agent_loop.agent_loop_nodes.count, "a refused append writes nothing"
    assert_equal "needs_attention", seam.agent_loop.reload.status,
      "the hold is never released behind a person's answer"

    # A status flip from elsewhere reaches no reopen and no settle: the
    # seam's variant is terminal and the person's edit is what renders.
    AgentLoops::Transition.agent_loop(seam.agent_loop, status: "running", attention_reason: nil)
    assert_equal 0, Conversations::Turns::Converge.call.value[:recorded]
    AgentLoops::Transition.agent_loop(seam.agent_loop, status: "completed", completed_at: Time.current)
    assert_equal 0, Conversations::Turns::Converge.call.value[:recorded]
    assert_equal edited.id, seam.turn.reload.active_variant_id
    assert_equal "completed", seam.turn.status
    assert_equal "failed", seam.variant.reload.status
    assert_nil @conversation.reload.active_turn_id

    assert_equal :variant_not_active, activate!(seam.turn, seam.variant).outcome,
      "a hold-settled sample is not a settled answer to swipe to"
  end

  test "regenerate declares through the TURN's answerer, not the conversation's default" do
    agent = users(:agent)
    written = PromptDocuments::Write.call(anchor: { user: agent }, slot: "system_prompt",
      content: "I am the agent.", role: nil)
    assert_predicate written, :written?, written.outcome.inspect
    accept!(kind: "direct_reply", text: "the prompt", provider_id: "dev", model_ref: "mock-text",
      answering_user_public_id: agent.public_id)
    drain!
    apply_via(admitted_attempt_for(@conversation), sse_success("first answer"))
    Conversations::Turns::Converge.call
    turn = @conversation.conversation_turns.order(:position).last.reload
    assert_equal [agent, @human], [turn.answering_user, @conversation.answering_user]

    result = regenerate!(turn, provider_id: "dev", model_ref: "mock-priced")
    assert_predicate result, :accepted?, result.outcome.inspect
    assert_includes request_texts(result.value), "I am the agent.",
      "the reassembled regeneration runs under the turn's answerer"
  end
end
