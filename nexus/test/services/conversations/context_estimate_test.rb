require "test_helper"

# The assembled-context estimate: the token-count contract wired to the
# conversation plane. Server-side assembly means only the server can count
# — the estimate runs the reply lane's exact assembly + normalization,
# counts through the declared contract, and stays advisory.
class Conversations::ContextEstimateTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
    @actor = Actors::Resolve.member(account: @account, user: @user)
  end

  def settle_turn!(position:, role:, text:)
    turn = ConversationTurn.create!(
      account: @account, conversation: @conversation, position: position,
      kind: "message", role: role, status: "completed",
      speaker_actor: @actor, control_owner_user: @user
    )
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "manual"
    )
    ContentBodies::Replace.call(
      owner: variant, role: "content", entries: [{ "text" => text }], seal: true
    )
    turn.update!(active_variant: variant)
    turn
  end

  def estimate!(prompt: nil, model: "mock-text", **overrides)
    Conversations::ContextEstimate.call(Conversations::ContextEstimate::Command.new(**{
      conversation: @conversation, acting_user: @user, provider_id: "dev", model_ref: model,
      reasoning_effort: nil, request_options: nil, prompt: prompt,
      history_max_entries: nil, history_token_budget_share: nil,
      reasoning_replay_mode: nil, inline: nil,
    }.merge(overrides)))
  end

  # The estimate's rule is the drain's: the CONVERSATION's answerer declares, never the estimating
  # caller — an agent estimating on a Human-answered conversation renders no `system_prompt`; a
  # Human estimating on an agent-answered one renders the answerer's.
  test "the estimate's declaring profile is the conversation's answerer, not the estimating agent" do
    agent = users(:agent)
    written = PromptDocuments::Write.call(anchor: { user: agent }, slot: "system_prompt",
      content: "I am the agent.", role: nil)
    assert_predicate written, :written?, written.outcome.inspect
    settle_turn!(position: 0, role: "user", text: "first question")
    baseline = estimate!(prompt: "second question", acting_user: agent).value.message_count

    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: agent)
    settle_turn!(position: 0, role: "user", text: "first question")
    answered = estimate!(prompt: "second question").value.message_count

    assert_equal baseline + 1, answered,
      "the answerer's system_prompt leads the Human's estimate; the agent's own estimate on a " \
      "Human-answered conversation carried none"
  end

  test "the assembled context counts through the declared contract with the catalog's limits" do
    settle_turn!(position: 0, role: "user", text: "first question")
    settle_turn!(position: 1, role: "assistant", text: "first answer")

    result = estimate!(prompt: "second question")

    assert_predicate result, :accepted?
    estimate = result.value
    assert_equal 3, estimate.message_count, "two settled turns plus the prompt"
    assert_operator estimate.input_tokens, :>, 0
    assert_not_nil estimate.catalog_input_token_limit,
      "the catalog's declared window rides along for the trim/compact decision"

    baseline = estimate.input_tokens
    settle_turn!(position: 2, role: "user", text: "a much longer message " * 40)
    grown = estimate!.value
    assert_operator grown.input_tokens, :>, baseline, "the estimate tracks the growing timeline"
  end

  test "concealed and excluded rows never count — the estimate reads the assembly surface" do
    settle_turn!(position: 0, role: "user", text: "kept")
    excluded = settle_turn!(position: 1, role: "user", text: "excluded " * 100)
    settle_turn!(position: 2, role: "assistant", text: "tail")
    excluded.update!(visibility: "excluded_from_context")

    with_excluded = estimate!.value
    assert_equal 2, with_excluded.message_count,
      "what assembly will not send, the estimate does not count"
  end

  test "adjacent same-role turns merge into one wire message" do
    settle_turn!(position: 0, role: "user", text: "first send")
    settle_turn!(position: 1, role: "user", text: "second send")
    settle_turn!(position: 2, role: "assistant", text: "one answer")

    merged = Conversations::ContextAssembly.assemble(
      conversation: @conversation, prompt: "and a prompt", principal: @user
    ).messages

    assert_equal %w[user assistant user], merged.map(&:role),
      "the wire rejects consecutive same-role messages; adjacency merges"
    assert_equal ["first send", "second send"], merged.first.parts.map(&:text), "each turn its own part, never folded"
    assert_equal "and a prompt", merged.last.parts.sole.text
  end

  test "history intent selects newest-first, renders chronological, and reports the evidence" do
    settle_turn!(position: 0, role: "user", text: "oldest question")
    settle_turn!(position: 1, role: "assistant", text: "oldest answer")
    settle_turn!(position: 2, role: "user", text: "newest question")

    result = estimate!(history_max_entries: 2)

    assert_predicate result, :accepted?
    estimate = result.value
    assert_equal 2, estimate.history_selected, "the tail is worth more than the head"
    assert_equal 1, estimate.history_skipped
    assert_equal "entry_limit", estimate.history_skipped_reason

    messages = Conversations::ContextAssembly.assemble(
      conversation: @conversation, history_max_entries: 2, principal: @user
    ).messages
    assert_equal %w[assistant user], messages.map(&:role),
      "the newest TWO, rendered in time order — the oldest pair dropped"
    assert_equal "newest question", messages.last.parts.sole.text
  end

  test "a token-budget share maps onto the model's own window and walks newest-first" do
    settle_turn!(position: 0, role: "user", text: "padding " * 400)
    settle_turn!(position: 1, role: "assistant", text: "short answer")

    tight = estimate!(history_token_budget_share: 0.01)

    assert_predicate tight, :accepted?
    assert_equal 1, tight.value.history_selected,
      "one percent of the window keeps only the newest entry"
    assert_equal "budget_exceeded", tight.value.history_skipped_reason

    roomy = estimate!(history_token_budget_share: 1.0)
    assert_equal 2, roomy.value.history_selected
    assert_equal 0, roomy.value.history_skipped
  end

  test "an unresolvable selection refuses the way the reply lane would" do
    assert_equal :unknown_model, estimate!(model: "no-such-model").outcome
    assert_equal :model_selection_missing, estimate!(model: nil).outcome
  end

  # The inline slot override is funded like the send: an entry naming a slot lands as the list's
  # first system item and counts.
  test "an inline slot override counts in the estimate like the send" do
    bare = estimate!(prompt: "x").value
    overridden = estimate!(prompt: "x", inline: [{ "slot" => "character", "text" => "You are the room." }]).value

    assert_equal bare.message_count + 1, overridden.message_count, "one system item ahead of the prompt"
    assert_operator overridden.input_tokens, :>, bare.input_tokens
  end

  # ── THE PREVIEW: the same call, rendered ─────────────────

  def declare!(agent, mechanism, template: nil)
    outcome = Users::DeclareConfiguration.call(user: agent, tool_definitions: [], approval_mode: nil, approval_rules: nil,
      prompt_mechanism: mechanism, prompt_template: template, compaction_policy: nil)
    assert_equal :declared, outcome.outcome, outcome.user.errors.full_messages.to_sentence
  end

  def register!(slot, content, on:, role: nil)
    result = PromptDocuments::Write.call(anchor: on, slot: slot, content: content, role: role)
    assert_predicate result, :written?, result.outcome.inspect
    result.document
  end

  TRIAL = {
    "blocks" => [
      { "type" => "inline", "role" => "developer", "text" => "Scene: {{scene}}." },
      { "type" => "history" }, { "type" => "input" },
    ],
    "variables" => { "scene" => "a quiet room" },
  }.freeze

  test "rendered, the estimate answers the entries, the storage line and the evidence — and writes nothing" do
    register!("character", "The room.", on: { workspace: @workspace })
    settle_turn!(position: 0, role: "user", text: "first question")

    result = nil
    assert_no_difference([
      -> { ModelInvocation.count }, -> { ContentBody.count }, -> { ContentFragment.count },
      -> { ConversationTurn.count }, -> { ConversationInput.count },
      -> { @conversation.conversation_event_items.count },
    ]) do
      result = estimate!(prompt: "second question", render: true)
    end
    assert_predicate result, :accepted?, result.outcome.inspect
    rendered = result.value.rendered

    assert_equal "default", rendered.mechanism, "no template in force: the built-in order"
    assert_equal %w[system user], rendered.entries.map { |entry| entry["role"] }
    assert_equal "The room.", rendered.entries[0].dig("parts", 0, "text")
    assert_equal ["first question", "second question"], rendered.entries[1].fetch("parts").map { |part| part["text"] }
    assert_equal ContentBodies::Measure.call(rendered.entries).bytes, rendered.storage.bytes
    assert_predicate rendered.storage, :within_bound?
    assert_equal %w[slot:system_prompt slot:character slot:persona memory skills history lead tail input],
      rendered.blocks.map(&:key), "the evidence in the template's order"
    assert_equal %w[empty selected empty empty empty selected empty empty selected], rendered.blocks.map(&:state)
    assert rendered.blocks.all? { |block| block.allocated_tokens.is_a?(Integer) }, "an 8192 window sizes every block"
    assert_equal({ "character" => 1 }, rendered.slots.versions, "R-28: the compiled documents' versions, by slot")
    assert_equal [0, 0], [rendered.memory.included, rendered.memory.omitted]
  end

  test "storage over the seal's bound still answers, with the seal's refusal word" do
    result = estimate!(prompt: "x" * (Nexus::SizeBounds.fetch(:snapshot_bound) + 1), render: true)

    assert_predicate result, :accepted?, result.outcome.inspect
    storage = result.value.rendered.storage
    assert_not_predicate storage, :within_bound?
    assert_equal Nexus::SizeBounds::REJECTION, storage.refusal
    assert_operator storage.bytes, :>, storage.bound
  end

  # `to:` resolves exactly as the input door does (TurnPrincipals, one
  # rule): unknown by name, a Human as ineligible, a peer profile as the
  # declaring profile whose template and slot the preview compiles under.
  test "the addressee is resolved as the input door resolves it, and the preview compiles under it" do
    peer = create_agent_member(display_name: "Peer", agent_identifier: "peer-agent")
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: users(:agent))
    register!("system_prompt", "I am the peer.", on: { user: peer }, role: "developer")
    declare!(peer, "assembly", template: TRIAL)

    assert_equal :principal_unknown, estimate!(answering_user_public_id: "@nobody-here").outcome
    assert_equal :answerer_not_eligible, estimate!(answering_user_public_id: users(:owner).public_id).outcome,
      "a Human never answers a turn"

    result = estimate!(prompt: "so?", render: true, answering_user_public_id: "@#{peer.handle}",
      variables: { "scene" => "a rainy night" })
    assert_predicate result, :accepted?, result.outcome.inspect
    rendered = result.value.rendered
    assert_equal "assembly", rendered.mechanism
    assert_equal %w[developer user], rendered.entries.map { |entry| entry["role"] }
    assert_equal "Scene: a rainy night.", rendered.entries[0].dig("parts", 0, "text"),
      "the peer's template, the turn's value over the default; the stored answerer's slot is not read"
    assert_equal %w[inline:0 history input], rendered.blocks.map(&:key)
  end

  test "a trial template compiles in place of the addressee's and is validated at its path; the turn's refusals hold" do
    result = estimate!(prompt: "so?", render: true, template: TRIAL)
    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal "assembly", result.value.rendered.mechanism, "the word the compile ran under"
    assert_equal "Scene: a quiet room.", result.value.rendered.entries[0].dig("parts", 0, "text")
    assert_equal "default", estimate!(prompt: "so?", render: true).value.rendered.mechanism,
      "the trial was never declared"

    bad = estimate!(template: TRIAL.merge("blocks" => TRIAL["blocks"] + [{ "type" => "memory" }]))
    assert_equal :prompt_template_invalid, bad.outcome
    assert_equal "/blocks/3", bad.value.path, "input must be last: the block after it, at its path"

    assert_equal :prompt_template_invalid, estimate!(variables: { "scene" => "x" }).outcome,
      "the built-in order declares no name"
    assert_equal :prompt_template_invalid, estimate!(template: TRIAL, variables: { "mood" => "x" }).outcome
    assert_equal :inline_position_unplaced,
      estimate!(template: TRIAL, inline: [{ "role" => "user", "text" => "t", "position" => "tail" }]).outcome
    assert_equal :inline_role_unplaced,
      estimate!(inline: [{ "role" => "system", "text" => "t", "position" => "lead" }]).outcome,
      "the preview refuses what the send refuses: a positioned entry rides the preface, never as system"
  end

  test "a raw addressee has nothing to compile and refuses by name" do
    agent = users(:agent)
    declare!(agent, "raw")
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: agent)

    assert_equal :estimate_unavailable_under_raw, estimate!(prompt: "so?").outcome
  end

  # Exclusion is EVIDENCE (exit-B M4): three slots the 8192 window cannot
  # fund are `floor_unmet` on bytes the preview still renders whole;
  # history yields to nothing and the request sends whole. Only the
  # drain's window gate refuses, on its own exact count.
  test "floors the window cannot fund read floor_unmet while every slot renders and history is empty" do
    agent = users(:agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: agent)
    big = "word " * 12_000
    register!("system_prompt", big, on: { user: agent })
    register!("character", big, on: { workspace: @workspace })
    register!("persona", big, on: { user: @user })
    settle_turn!(position: 0, role: "user", text: "kept?")

    result = estimate!(prompt: "so?", render: true)

    assert_predicate result, :accepted?, result.outcome.inspect
    rendered = result.value.rendered
    by_key = rendered.blocks.index_by(&:key)
    assert_equal %w[floor_unmet] * 3, %w[slot:system_prompt slot:character slot:persona].map { |key| by_key.fetch(key).state }
    assert_equal "empty", by_key.fetch("history").state
    assert_equal 0, result.value.history_selected
    assert_equal "budget_exceeded", result.value.history_skipped_reason
    assert_equal [big.length] * 3, rendered.entries[0].fetch("parts").map { |part| part["text"].length },
      "every slot renders whole into the one system item, each its own part"
    assert_operator result.value.input_tokens, :>, result.value.catalog_input_token_limit,
      "the count says what the window gate will refuse; the preview itself does not"
  end

  test "on a windowless model no block is sized: allocated_tokens nil throughout" do
    settle_turn!(position: 0, role: "user", text: "one")
    settle_turn!(position: 1, role: "assistant", text: "two")

    result = estimate!(prompt: "three", render: true, model: "mock-windowless")

    assert_predicate result, :accepted?, result.outcome.inspect
    assert result.value.rendered.blocks.all? { |block| block.allocated_tokens.nil? }
    assert_equal 2, result.value.history_selected
  end
end
