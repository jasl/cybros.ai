module InputsApplyNextTestHelper
  extend ActiveSupport::Concern

  included do
    include ActiveJob::TestHelper

    setup do
      @account = accounts(:cybros)
      @workspace = workspaces(:shared)
      @user = users(:member)
      @agent = users(:agent)
      DevModelLane.ensure_enabled!(@account)
      @conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
    end
  end

  READ_TOOL = {
    "type" => "function",
    "function" => { "name" => "read_file", "parameters" => { "type" => "object" } },
  }.freeze
  WRITE_TOOL = {
    "type" => "function",
    "function" => { "name" => "write_file", "parameters" => { "type" => "object" } },
  }.freeze

  def accept!(text: "hello", **overrides)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
      host: @conversation, acting_user: @user, kind: "message",
      role: "user", entries: [{ "text" => text }], visible_in_context: true,
      delivery_mode: "queue", context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
    assert_predicate result, :accepted?
    result.value
  end

  def drain! = Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)

  # The gate behind a hold: a hold at rest is moved only by a person, so a row queued before it and
  # the kernel's mail wait; the person's next word is the repair, and the successor wakes the
  # converger to stop the loop it replaced.
  def hold_settled_seam!(before: nil)
    seam = create_run_backed_turn(conversation: @conversation.reload, acting_user: @user)
    queued = before && accept!(text: before)
    AgentRuns::Transition.agent_run(seam.agent_run, status: "needs_attention",
      attention_reason: "halt_failure")
    Conversations::Turns::Converge.call
    assert_equal "failed", seam.turn.reload.status
    [seam, queued]
  end

  def blocked_items
    @conversation.conversation_event_items.where(item_type: "input_blocked").order(:sequence)
  end

  ENVELOPE = "<task_result task=\"r2t0\" status=\"completed\">done</task_result>".freeze

  # The receipt's shape: a kernel-stamped `direct_reply` on the mailing loop's surface, sent as the
  # loop's creator. The flat `message` shape is the notice with nothing to wake.
  def kernel_result_delivery!(acting_user: @user, kind: "message", **surface)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
      host: @conversation, acting_user: acting_user, kind: kind, entries: [{ "text" => ENVELOPE }],
      origin: ConversationInput::TASK_RESULT_ORIGIN, sender_conversation_public_id: @conversation.public_id,
      **surface
    ))
    assert_predicate result, :accepted?
    result.value
  end

  def materialized_items
    @conversation.conversation_event_items.where(item_type: "input_materialized").order(:sequence)
  end

  # ── The engine choice ────────────────────────────────── A `direct_reply` head materializes a
  # kernel loop iff its declaring profile — the conversation's ANSWERER, whoever posted the head —
  # carries tools; every other head is the direct reply it always was.

  def declare!(agent, tools: [READ_TOOL], prompt_mechanism: nil, approval_mode: "bypass",
               approval_rules: nil, compaction_policy: { "mode" => "kernel" }, prompt_template: nil)
    outcome = Users::DeclareConfiguration.call(user: agent,
      tool_definitions: tools, approval_mode: approval_mode, approval_rules: approval_rules,
      prompt_mechanism: prompt_mechanism, prompt_template: prompt_template, compaction_policy: compaction_policy
    )
    assert_equal :declared, outcome.outcome, outcome.user.errors.full_messages.join
    agent
  end

  ASSEMBLY_TEMPLATE = {
    "blocks" => [
      { "type" => "inline", "role" => "user", "text" => "Scene: {{scene}}." },
      { "type" => "history" }, { "type" => "input" },
    ],
    "variables" => { "scene" => "an ordinary day" },
  }.freeze

  def reply!(acting_user: @user, text: "what is up", **overrides)
    accept!(**{ text: text, kind: "direct_reply", acting_user: acting_user,
                provider_id: "dev", model_ref: "mock-text" }.merge(overrides))
  end

  def reply_variant = @conversation.conversation_turns.order(:position).last.active_variant

  # A fresh lane ANSWERED by the agent: the engine is the conversation's stored answerer's, whoever
  # posts the head.
  def answered_by!(agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: agent)
  end

  def input_entries(node)
    body = node.content_bodies.find_by!(role: "input")
    assert_predicate body, :sealed?, "round one's body is sealed at materialization"
    body.content_body_entries.map { |entry| entry.content_fragment.payload }
  end
  # ── the caller's clock at the drain ──

  def scheduled!(text:, at:, **overrides) = accept!(text: text, deliver_at: at, **overrides)

  def turn_texts
    @conversation.conversation_turns.order(:position).map do |turn|
      turn.active_variant.content_bodies.sole.effective_text
    end
  end
end
