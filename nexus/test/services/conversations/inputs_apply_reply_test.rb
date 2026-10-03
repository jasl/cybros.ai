require "test_helper"
require_relative "../../test_helpers/inputs_apply_next_test_helper"

class Conversations::InputsApplyReplyTest < ActiveSupport::TestCase
  include InputsApplyNextTestHelper

  # The effective mechanism on the loop row is the profile's standing word; the template's inline
  # opens round one's input.
  test "the loop-backed turn under assembly writes its word and opens with the template's own text" do
    answered_by!(@agent)
    declare!(@agent, prompt_mechanism: "assembly", prompt_template: ASSEMBLY_TEMPLATE)
    reply!(acting_user: @user, text: "and so?", context_options: { "variables" => { "scene" => "a rainy night" } })

    assert_equal 1, drain!
    assert_equal "assembly", reply_variant.agent_loop.prompt_mechanism
    entries = input_entries(reply_variant.agent_loop.agent_loop_nodes.sole)
    assert_equal ["Scene: a rainy night.", "and so?"], entries.sole.fetch("parts").map { |part| part["text"] },
      "the inline and the input are adjacent user segments: one item, each its own part"
  end

  # kernel-B M5: the door validated against the row of its day; the
  # profile re-declared since. The name the CURRENT template does not
  # declare parks the head by name — never literal braces, never a drop.
  test "a variable the re-declared template no longer names parks the head prompt_template_invalid" do
    answered_by!(@agent)
    declare!(@agent, prompt_mechanism: "assembly", prompt_template: ASSEMBLY_TEMPLATE)
    input = reply!(acting_user: @user, text: "go", context_options: { "variables" => { "scene" => "dawn" } })
    declare!(@agent, prompt_mechanism: "assembly", prompt_template: {
      "blocks" => [{ "type" => "inline", "role" => "user", "text" => "Mood: {{mood}}." }] + ASSEMBLY_TEMPLATE.fetch("blocks").drop(1),
      "variables" => { "mood" => "calm" },
    })

    assert_equal 0, drain!
    assert_equal "blocked", input.reload.state
    assert_equal "prompt_template_invalid", input.blocked_reason
    assert_equal 0, AgentLoop.count

    declare!(@agent, prompt_mechanism: "assembly",
      prompt_template: ASSEMBLY_TEMPLATE.merge("blocks" => ASSEMBLY_TEMPLATE.fetch("blocks").drop(1)))
    tail = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: @conversation, acting_user: @user, kind: "direct_reply", role: "user", entries: [{ "text" => "again" }],
      visible_in_context: true, delivery_mode: "queue", context_mode: nil,
      context_options: { "inline" => [{ "role" => "user", "text" => "t", "position" => "tail" }] },
      expected_context_revision: nil, expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: "mock-text",
      reasoning_effort: nil, request_options: nil
    ))
    assert_predicate tail, :invalid?, "the door reads the addressee's template: no tail block, no tail entry"
    assert tail.record.errors.of_kind?(:context_options, :inline_position_unplaced)
  end

  # exit-B M4, pin (a): three full slots outfund the window — the request
  # still compiles WHOLE (no slot dropped, history to nothing) and only the
  # window gate refuses, on the exact count against the hard bound.
  test "three full slots on the dev window block the head at the window gate with no slot dropped" do
    answered_by!(@agent)
    declare!(@agent)
    PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt", content: "s" * 65_000)
    PromptDocuments::Write.call(anchor: { workspace: @workspace }, slot: "character", content: "c" * 65_000)
    PromptDocuments::Write.call(anchor: { user: @user }, slot: "persona", content: "p" * 65_000)
    input = reply!(acting_user: @user, text: "go")

    assert_equal 0, drain!
    assert_equal "blocked", input.reload.state
    assert_equal "estimated_input_exceeds_model_limit", input.blocked_reason
    assert_equal 0, AgentLoop.count
  end

  test "a human's reply head on a human's conversation stays a direct reply" do
    accept!(text: "history")
    reply!

    assert_equal 2, drain!
    assert_equal "inference", reply_variant.source
    assert_not_nil reply_variant.model_invocation_id
    assert_equal 0, AgentLoop.count
  end

  test "a head on a conversation ANSWERED by an agent whose profile carries tools materializes a loop born running" do
    answered_by!(@agent)
    declare!(@agent)
    accept!(text: "materialize me first")
    input = reply!(acting_user: @agent, request_options: { "max_output_tokens" => 64 })

    assert_enqueued_with(job: AgentLoops::ScheduleJob) do
      assert_no_enqueued_jobs(only: ModelInvocations::AdmitQueuedWorkJob) do
        assert_equal 2, drain!
      end
    end

    turn = @conversation.conversation_turns.order(:position).last
    assert_equal %w[direct_reply assistant running], [turn.kind, turn.role, turn.status]
    assert_equal @agent.id, turn.control_owner_user_id
    assert_not ConversationInput.exists?(input.id), "the input dies with its materialization"
    @conversation.reload
    assert_equal turn.id, @conversation.active_turn_id, "the lane is busy"
    assert_equal 2, @conversation.timeline_position_head

    variant = turn.active_variant
    assert_equal "agent_loop", variant.source
    assert_equal "running", variant.status
    assert_nil variant.model_invocation_id, "a loop-backed variant names no invocation"
    assert_equal %w[dev mock-text], [variant.provider_id, variant.model_ref]

    agent_loop = AgentLoop.sole
    assert_equal variant.id, agent_loop.conversation_turn_variant_id, "the seam's production writer"
    assert_equal agent_loop, variant.agent_loop
    assert_equal "running", agent_loop.status, "born running: the person's input is the start"
    assert_not_nil agent_loop.started_at
    assert_equal @agent.id, agent_loop.creating_user_id
    assert_equal @workspace.id, agent_loop.workspace_id
    assert_not_nil agent_loop.conversation_event_cursor, "born with its cursor"
    assert_equal @conversation, agent_loop.conversation

    r1 = agent_loop.agent_loop_nodes.sole
    assert_equal "r1", r1.node_key
    assert_equal "queued", r1.status, "round one is minted by the scheduler like every round"
    assert_equal [READ_TOOL], r1.tool_definitions, "the declaration, frozen onto the round"
    assert_equal({ "mode" => "kernel" }, r1.compaction)
    assert_nil r1.system_instructions, "the system channel rides the sealed list"
    assert_equal({ "max_output_tokens" => 64 }, r1.request_options, "the SUBMITTED options")
    assert_equal "round", r1.continuation_source
    assert_equal "halt", r1.on_failure
    assert_equal "visible", r1.transcript_visibility
    assert_equal 0, r1.retry_budget
    assert_equal %w[dev mock-text], [r1.provider_id, r1.model_ref]
    assert_equal r1.id, agent_loop.deliverable_node_id, "materialization designates r1"

    entries = input_entries(r1)
    assert entries.all? { |payload| payload.key?("role") && payload.key?("parts") },
      "entries-shaped: the assembled message list, never a text prompt"
    assert_equal ["materialize me first", "what is up"], entries.sole.fetch("parts").map { |part| part["text"] },
      "the same normalized elements a direct reply seals: one item, each segment its own part"

    items = @conversation.conversation_event_items.order(:sequence)
      .map { |item| [item.item_type, item.payload] }
    assert_equal %w[input_accepted input_accepted input_materialized turn_created
                    input_materialized turn_created turn_status task_status turn_status],
      items.map(&:first)
    materialized = items.map(&:last).find { |payload| payload["turn_public_id"] == turn.public_id }
    assert_equal input.public_id, materialized["input_public_id"]
    reply_status, loop_status = items.select { |type, _| type == "turn_status" }.map(&:last)
    assert_equal turn.public_id, reply_status["turn_public_id"]
    assert_equal variant.public_id, reply_status["variant_public_id"]
    assert_equal "running", reply_status["status"]
    assert_equal agent_loop.public_id, reply_status["agent_loop_public_id"],
      "the correlation key rides the turn's own status item"
    assert_equal "running", loop_status["loop_status"]
    assert_equal turn.public_id, loop_status["turn_public_id"]
    assert_not loop_status.key?("status"), "on a conversation host the turn row is settle's to narrate"
    assert_equal %w[direct_reply direct_reply], [reply_status["turn_kind"], loop_status["turn_kind"]],
      "both writers name the turn's kind (the follower's turn kind, 2026-09-18)"
    task = items.find { |type, _| type == "task_status" }.last
    assert_equal "r1", task["task_key"]
  end

  test "a human's word on a conversation answered by an agent declares through the ANSWERING agent" do
    declare!(@agent)
    answered_by!(@agent)
    reply!

    assert_equal 1, drain!
    assert_equal "agent_loop", reply_variant.source, "a Human's word, an agent's engine"
    agent_loop = reply_variant.agent_loop
    assert_equal @user.id, agent_loop.creating_user_id, "the loop is the author's"
    assert_equal @agent, agent_loop.answering_user, "and answers as its conversation does"
    assert_equal [READ_TOOL], agent_loop.agent_loop_nodes.sole.tool_definitions
  end

  # The hijack's inverse (the gap plan's rank-1 finding): the speaker does
  # not bring its engine — an agent's post into a Human-answered
  # conversation is the plain reply that conversation always has.
  test "an agent's post into a Human-answered conversation is a plain reply" do
    declare!(@agent)
    reply!(acting_user: @agent)

    assert_equal 1, drain!
    assert_equal "inference", reply_variant.source
    assert_not_nil reply_variant.model_invocation_id
    assert_equal 0, AgentLoop.count, "the poster's declaration is not this conversation's engine"
  end

  # The turn's tool subset (compose switch design, decision 1): the seed freezes the declaration
  # narrowed by the input's names — the same bytes, fewer of them — and a later turn that names none
  # gets the whole set, because the freeze is per TURN and the row is the turn's request.
  test "the input's tool_names narrows the frozen declaration by name, per turn" do
    answered_by!(@agent)
    declare!(@agent, tools: [READ_TOOL, WRITE_TOOL])
    reply!(acting_user: @agent, tool_names: %w[read_file])

    assert_equal 1, drain!
    r1 = reply_variant.agent_loop.agent_loop_nodes.sole
    assert_equal [READ_TOOL], r1.tool_definitions, "a subset of the declaration, by name"
    assert_equal [READ_TOOL, WRITE_TOOL], @agent.reload.tool_definitions,
      "the declaration itself is untouched — the narrowing is the input's, not the profile's"

    AgentLoops::Transition.agent_loop(reply_variant.agent_loop, status: "completed",
      completed_at: Time.current)
    Conversations::Turns::Converge.call
    reply!(acting_user: @agent)
    assert_equal 1, drain!
    assert_equal [READ_TOOL, WRITE_TOOL], reply_variant.agent_loop.agent_loop_nodes.sole.tool_definitions,
      "the next turn names none and carries the whole declaration"
  end

  # NO TOOLS AT ALL (rho's `btw`): an empty list is a reply from context alone — still the declaring
  # profile's engine, a loop whose round r1 freezes an EMPTY set, so the request carries no tools
  # and the model can only answer. Never the whole declaration: nil is that.
  test "an empty tool_names is a loop-backed reply that freezes no tools" do
    answered_by!(@agent)
    declare!(@agent, tools: [READ_TOOL, WRITE_TOOL])
    reply!(acting_user: @agent, tool_names: [])

    assert_equal 1, drain!
    r1 = reply_variant.agent_loop.agent_loop_nodes.sole
    assert_empty Array(r1.tool_definitions), "no tools on the round (the loop plane's nil), not the whole declaration"
    assert_equal "agent_loop", reply_variant.source, "the declaring profile's engine still answers"
  end

  # The approval freeze: the input's tightening rides onto the loop row for that turn; the next turn
  # that names none freezes the profile's own word, and the profile's rule list rides every turn.
  test "the input's approval_mode tightens the frozen mode per turn, and a loosening is refused" do
    answered_by!(@agent)
    rules = [{ "tool" => "read_file", "verdict" => "allow" }]
    declare!(@agent, tools: [READ_TOOL], approval_mode: "bypass", approval_rules: rules)
    reply!(acting_user: @agent, approval_mode: "ask")

    assert_equal 1, drain!
    frozen = reply_variant.agent_loop
    assert_equal "ask", frozen.approval_mode, "the turn runs under the tightening"
    assert_equal rules, frozen.approval_rules, "the profile's rules ride the turn"
    assert_equal "bypass", @agent.reload.approval_mode, "the declaration itself is untouched"

    AgentLoops::Transition.agent_loop(frozen, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call
    reply!(acting_user: @agent)
    assert_equal 1, drain!
    assert_equal "bypass", reply_variant.agent_loop.approval_mode, "the next turn names none and carries the profile's word"

    declare!(@agent, tools: [READ_TOOL], approval_mode: "ask")
    refused = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: @conversation, acting_user: @agent, kind: "direct_reply", role: "user",
      entries: [{ "text" => "loosen" }], visible_in_context: true, delivery_mode: "queue",
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: "mock-text",
      reasoning_effort: nil, request_options: nil, approval_mode: "bypass"
    ))
    assert_predicate refused, :invalid?
    assert refused.record.errors.of_kind?(:approval_mode, :not_tightening)
  end

  test "a declaring agent with an empty tool set is a direct reply" do
    answered_by!(@agent)
    declare!(@agent, tools: [])
    assert_nil @agent.reload.tool_definitions
    reply!(acting_user: @agent)

    assert_equal 1, drain!
    assert_equal "inference", reply_variant.source
    assert_equal 0, AgentLoop.count
  end

  test "raw from the profile and raw from the input both seal the input's own entries" do
    answered_by!(@agent)
    declare!(@agent, prompt_mechanism: "raw")
    accept!(text: "history that must NOT ride")
    reply!(acting_user: @agent, text: "just this")
    assert_equal 2, drain!
    entries = input_entries(reply_variant.agent_loop.agent_loop_nodes.sole)
    assert_equal [{ "text" => "just this" }], entries,
      "the profile's raw: the input's lone text, no history, no enrichment"

    declare!(@agent, prompt_mechanism: "default")
    AgentLoops::Transition.agent_loop(reply_variant.agent_loop, status: "completed",
      completed_at: Time.current)
    Conversations::Turns::Converge.call
    reply!(acting_user: @agent, context_mode: "raw",
      entries: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "and this" }] }])
    assert_equal 1, drain!
    entries = input_entries(reply_variant.agent_loop.agent_loop_nodes.sole)
    assert_equal 1, entries.length
    assert_equal "and this", entries.sole.dig("parts", 0, "text"), "the input's raw"
  end

  test "no model on the head still blocks it — the declaration names none" do
    declare!(@agent)
    input = accept!(text: "go", kind: "direct_reply", acting_user: @agent)

    assert_equal 0, drain!
    assert_equal "blocked", input.reload.state
    assert_equal "model_selection_missing", input.blocked_reason
    assert_equal 0, AgentLoop.count
  end

  test "the window gate runs before either engine: a prompt that cannot fit leaves no loop behind" do
    answered_by!(@agent)
    declare!(@agent)
    input = reply!(acting_user: @agent, text: SecureRandom.hex(20_000))

    assert_equal 0, drain!
    assert_equal "blocked", input.reload.state
    assert_equal "estimated_input_exceeds_model_limit", input.blocked_reason
    assert_equal 0, AgentLoop.count
    assert_equal 0, @conversation.conversation_turns.count
  end

  # THE WINDOW THE KERNEL PLANS TO gates the request: a lane fitted short of its hard window — an
  # advisory bound under it — refuses at the fit, where assembly and the compaction arms already
  # read (`planning_input_bound`), never at the hard bound alone. The two bounds are set apart and
  # the prompt lands between them.
  test "the window gate reads the planning bound, not the hard one" do
    answered_by!(@agent)
    declare!(@agent)
    real_new = Nexus::ModelCapabilityLimits.method(:new)
    planned_short = ->(**bounds) { real_new.call(**bounds, effective_input_tokens: 1_024) }
    Nexus::ModelCapabilityLimits.stub(:new, planned_short) do
      input = reply!(acting_user: @agent, text: SecureRandom.hex(3_000))

      assert_equal 0, drain!
      assert_equal "blocked", input.reload.state
      assert_equal "estimated_input_exceeds_model_limit", input.blocked_reason
    end
    assert_equal 0, AgentLoop.count
  end

  test "the wall arms the timeline compaction before any loop exists" do
    answered_by!(@agent)
    declare!(@agent)
    5.times { |n| accept!(text: "turn#{n} #{SecureRandom.hex(2_000)}") }
    drain!
    reply!(acting_user: @agent, text: "and now what #{SecureRandom.hex(1_500)}",
      context_options: { "history" => { "token_budget_share" => 1.0 } })

    assert_equal 0, drain!
    summary = @conversation.conversation_turns.find_by!(kind: "compaction_summary")
    assert_equal "running", summary.status
    assert_equal "pending", @conversation.conversation_inputs.sole.state,
      "the head waits behind the summary and drains again"
    # The summary is the ONE loop: the kernel's own one-task loop behind
    # the summary turn, its deliverable the summarizer — never the reply's.
    assert_equal 1, AgentLoop.count
    assert_equal "compaction_summary", AgentLoop.sole.conversation_turn.kind
    assert_equal "k1", AgentLoop.sole.deliverable.node_key
    # The follower's turn kind: a `say` queued behind this summary watches the summarizer's loop
    # narrate first, and the loop's own item says WHICH turn it is, so the follower keeps waiting
    # for the person's turn instead of naming the summarizer's loop.
    status = @conversation.conversation_event_items.where(item_type: "turn_status").sole.payload
    assert_equal summary.public_id, status["turn_public_id"]
    assert_equal AgentLoop.sole.public_id, status["agent_loop_public_id"]
    assert_equal "compaction_summary", status["turn_kind"]
  end

  # THE LESSER FALLBACK of the fit wall (cache audit 2026-09-16, prefix-4):
  # the fit overflow arms the summary; when no summary can be armed — the
  # author's `off` here, a summary that itself overflows the fit — the
  # request still goes, trimmed to the fit and narrated as the trim it is.
  # The fit is the kernel's own preference (the cache), never a "will not
  # go": a request under the window is never blocked for it.
  test "under a policy of off the fit overflow slides, narrated as a trim, instead of blocking" do
    answered_by!(@agent)
    declare!(@agent, tools: [], compaction_policy: { "mode" => "off" })
    accept!(text: SecureRandom.hex(20_000))
    drain!
    reply!(acting_user: @agent)

    assert_equal 1, drain!
    assert_nil @conversation.conversation_turns.find_by(kind: "compaction_summary")
    assert_equal 0, @conversation.conversation_inputs.count, "the reply materialized"
    trimmed = @conversation.conversation_event_items.where(item_type: "context_trimmed").sole
    assert_equal 0, trimmed.payload["history_selected"]
    assert_equal "budget_exceeded", trimmed.payload["history_skipped_reason"]
  end

  # `raw`'s `instructions` is the wire's own system field: sealed as
  # `request_options["instructions"]` on a tool-less reply, as `system_instructions` on the
  # loop-backed seed — one copy per round, inherited by every continuation — and refused on an
  # assembled input.
  test "raw's instructions seal as the system field on both engines, and an assembled input refuses them" do
    reply!(context_mode: "raw", instructions: "Be brief.",
      entries: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "just this" }] }])
    assert_equal 1, drain!
    assert_equal "inference", reply_variant.source
    assert_equal "Be brief.", reply_variant.model_invocation.request_options.fetch("instructions")

    # A fresh lane, answered by the agent: the direct reply above is still running.
    answered_by!(@agent)
    declare!(@agent)
    reply!(acting_user: @agent, context_mode: "raw", instructions: "Be terse.",
      entries: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "and this" }] }])
    assert_equal 1, drain!
    agent_loop = reply_variant.agent_loop
    r1 = agent_loop.agent_loop_nodes.find_by!(node_key: "r1")
    assert_equal "Be terse.", r1.system_instructions
    assert_equal "raw", agent_loop.prompt_mechanism
    continuation = AgentLoops::Tasks::Step.inheriting(r1)
    assert_equal "Be terse.", continuation.instructions, "every continuation inherits the field"

    refused = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: @conversation, acting_user: @user, kind: "direct_reply", role: "user",
      entries: [{ "text" => "assembled" }], visible_in_context: true, delivery_mode: "queue",
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: "mock-text",
      reasoning_effort: nil, request_options: nil, instructions: "Be brief."
    ))
    assert_predicate refused, :invalid?
    assert refused.record.errors.of_kind?(:instructions, :invalid)
  end

  # THE SEED: a reply head's body is cloned onto the variant as its `prompt` before the row dies —
  # both engines through `land_reply`, the kernel's receipt included — so a later turn's history can
  # render the words that opened the turn ahead of what it produced.
  test "a reply turn's variant carries the input's body as prompt, sealed, zero bytes, on both engines" do
    answered_by!(@agent)
    input = reply!
    fragment_ids = input.content_body.content_body_entries.pluck(:content_fragment_id)
    assert_equal 1, drain!
    assert_equal "inference", reply_variant.source
    prompt = reply_variant.content_bodies.find_by!(role: "prompt")
    assert_predicate prompt, :sealed?
    assert_equal "what is up", prompt.readable_text
    assert_equal fragment_ids, prompt.content_body_entries.pluck(:content_fragment_id),
      "seal-then-clone: the same fragments, zero content bytes"
    assert_not ConversationInput.exists?(input.id)

    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocation.where(conversation_id: @conversation.id).update_all(status: "completed")
    @conversation.conversation_turns.order(:position).last.update!(status: "completed")
    @conversation.reload.update!(active_turn: nil)

    declare!(@agent)
    mail = kernel_mail!(acting_user: @agent, kind: "direct_reply", provider_id: "dev", model_ref: "mock-text")
    assert_equal 1, drain!
    assert_equal "agent_loop", reply_variant.source, "the receipt WOKE a loop-backed turn under the answerer's engine"
    assert_equal ENVELOPE, reply_variant.content_bodies.find_by!(role: "prompt").readable_text,
      "the woken turn's prompt is the envelope — the one copy a later history renders"
    assert_not ConversationInput.exists?(mail.id)
  end

  # THE PREFACE beside the seed: what the request laid between history and the input — the
  # client's positioned lead under the built-in order — sealed on the variant at the same landing,
  # on both engines. A slot override rides the leading run and a lead-first template's lead rides
  # ahead of history: neither is the turn's to replay, so neither is sealed.
  test "a reply turn's variant carries its post-history run as preface, sealed, on both engines" do
    lead = { "inline" => [{ "role" => "developer", "position" => "lead", "text" => "env" }] }
    sealed_preface = [{ "role" => "developer", "parts" => [{ "type" => "text", "text" => "env" }], "block" => "lead" }]

    answered_by!(@agent)
    reply!(context_options: lead)
    assert_equal 1, drain!
    assert_equal "inference", reply_variant.source
    preface = reply_variant.content_bodies.find_by!(role: "preface")
    assert_predicate preface, :sealed?
    assert_equal sealed_preface, preface.entry_payloads

    answered_by!(@agent)
    declare!(@agent)
    reply!(context_options: lead)
    assert_equal 1, drain!
    assert_equal "agent_loop", reply_variant.source
    assert_equal sealed_preface, reply_variant.content_bodies.find_by!(role: "preface").entry_payloads

    answered_by!(@agent)
    reply!(context_options: { "inline" => [{ "slot" => "persona", "text" => "P" }] })
    assert_equal 1, drain!
    assert_nil reply_variant.content_bodies.find_by(role: "preface"), "a slot override is not the turn's preface"

    answered_by!(@agent)
    declare!(@agent, prompt_mechanism: "assembly", prompt_template: { "blocks" => [
      { "type" => "lead" }, { "type" => "history" }, { "type" => "input" },
    ] })
    reply!(context_options: lead)
    assert_equal 1, drain!
    assert_nil reply_variant.content_bodies.find_by(role: "preface"), "a lead ahead of history is the template's prefix"
  end

  test "a raw input's prompt body is kept and renders nothing" do
    answered_by!(@agent)
    declare!(@agent)
    accept!(text: "history that rides")
    reply!(acting_user: @agent, context_mode: "raw",
      entries: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "and this" }] }])
    assert_equal 2, drain!
    turn = @conversation.conversation_turns.order(:position).last
    prompt = turn.active_variant.content_bodies.find_by!(role: "prompt")
    assert_nil prompt.readable_text, "entries-shaped: the record of what opened the turn, no text to render"

    AgentLoops::Transition.agent_loop(turn.active_variant.agent_loop, status: "completed",
      completed_at: Time.current)
    Conversations::Turns::Converge.call
    segments = Conversations::ContextAssembly::ChatHistory.call(conversation: @conversation.reload).segments
    assert_equal ["history that rides"], segments.map(&:text), "no seed segment for the raw turn"
  end

  test "the loop-backed turn writes its mechanism word: default when assembled, raw when raw" do
    answered_by!(@agent)
    declare!(@agent)
    reply!(acting_user: @agent)
    assert_equal 1, drain!
    assert_equal "default", reply_variant.agent_loop.prompt_mechanism
    assert_nil reply_variant.model_invocation_id
    r1 = reply_variant.agent_loop.agent_loop_nodes.sole
    assert_nil r1.system_instructions, "the assembled lane carries no system field"

    AgentLoops::Transition.agent_loop(reply_variant.agent_loop, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call
    reply!(acting_user: @agent, context_mode: "raw",
      entries: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "raw" }] }])
    assert_equal 1, drain!
    assert_equal "raw", reply_variant.agent_loop.prompt_mechanism
  end

  # ── the addressee on the reply turn ───────────────────────

  # A `to: B` head opens B's turn: B's engine (a loop with B's tools frozen on round one), the
  # turn's `answering_user` = B, the POSTER's speaker and control — while the conversation's default
  # stays what it was; a message turn takes the conversation's answerer.
  test "a head addressed to an agent materializes that agent's turn, on a Human's conversation" do
    declare!(@agent)
    accept!(text: "history")
    reply!(answering_user_public_id: "@#{@agent.handle}")

    assert_equal 2, drain!
    message, reply = @conversation.conversation_turns.order(:position).to_a
    assert_equal @user, message.answering_user, "a message turn carries the conversation's answerer"
    assert_equal @agent, reply.answering_user, "the reply turn carries the input's addressee"
    assert_equal [@user.id, @user.public_id], [reply.control_owner_user_id, reply.speaker_actor.external_id],
      "the poster keeps control and voice"
    assert_equal "agent_loop", reply.active_variant.source, "the addressee's engine: a loop, with its tools"
    agent_loop = reply.active_variant.agent_loop
    assert_equal @agent, agent_loop.answering_user, "the loop derives from the TURN"
    assert_equal @agent, agent_loop.declaring_profile
    assert_equal @user, agent_loop.creating_user
    assert_equal [READ_TOOL], agent_loop.agent_loop_nodes.find_by!(node_key: "r1").tool_definitions,
      "the addressee's declaration froze on round one"
    assert_equal @user, @conversation.reload.answering_user, "the default did not move"

    created = @conversation.conversation_event_items.where(item_type: "turn_created").order(:sequence)
    assert_equal [@user.public_id, @agent.public_id], created.map { |item| item.payload.fetch("answering_user_public_id") },
      "`turn_created` names the answerer on every kind"
  end
end
