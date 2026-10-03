require "test_helper"

# THE SAME-BYTES PAIR: the rendered estimate's `entries` ARE the sealed request of the send that
# follows — entry for entry, byte for byte — under `default` and under `assembly`, on a 1:1
# conversation and on a group conversation addressed away from the stored answerer. The pair holds
# because the estimate and the drain resolve the turn's principals through ONE rule
# (Conversations::TurnPrincipals): the caller authors, the addressee declares. And the preview
# writes nothing.
class Conversations::PromptPreviewBytesTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  TEMPLATE = {
    "blocks" => [
      { "type" => "slot", "slot" => "system_prompt" },
      { "type" => "inline", "role" => "user", "text" => "Scene: {{scene}}, with {{agent}}." },
      { "type" => "slot", "slot" => "persona" },
      { "type" => "memory" },
      { "type" => "history" },
      { "type" => "input" },
    ],
    "variables" => { "scene" => "an ordinary day" },
  }.freeze

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @creator = users(:member)
    @poster = users(:owner)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    register!("character", "This is the room.", on: { workspace: @workspace })
    register!("persona", "This is the poster.", on: { user: @poster }, role: "user")
    register!("system_prompt", "I am the fixture agent.", on: { user: @agent }, role: "developer")
  end

  def register!(slot, content, on:, role: nil)
    result = PromptDocuments::Write.call(anchor: on, slot: slot, content: content, role: role)
    assert_predicate result, :written?, result.outcome.inspect
  end

  def declare!(agent, mechanism, template: nil)
    outcome = Users::DeclareConfiguration.call(user: agent, tool_definitions: [], approval_mode: nil, approval_rules: nil,
      prompt_mechanism: mechanism, prompt_template: template, compaction_policy: nil)
    assert_equal :declared, outcome.outcome, outcome.user.errors.full_messages.to_sentence
  end

  def conversation_answered_by(answerer)
    conversation = Conversation.create!(workspace: @workspace, creating_user: @creator, answering_user: answerer)
    written = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: conversation, path: "workspace/notes.md", by: @creator), conversation: conversation, path: "workspace/notes.md",
      content: "gate code 4471", by: @creator)
    assert_predicate written, :accepted?, written.outcome.inspect
    conversation
  end

  # A settled turn SPOKEN by `speaker` and answered by `answerer`; a
  # `direct_reply` answered by the stored answerer reads, to another
  # addressee, as that agent's message (ChatHistory's peer-reply rule).
  def settle_turn!(conversation, text, speaker:, role:, answerer: speaker, kind: "message")
    position = conversation.conversation_turns.count
    turn = ConversationTurn.create!(
      account: @account, conversation: conversation, position: position, kind: kind, role: role,
      status: "completed", speaker_actor: Actors::Resolve.member(account: @account, user: speaker),
      control_owner_user: speaker, answering_user: answerer, visibility: "visible"
    )
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn, position: 0, status: "completed", source: "manual"
    )
    ContentBodies::Replace.call(owner: variant, role: "content", entries: [{ "text" => text }], seal: true)
    turn.update!(active_variant: variant)
    conversation.reload.update!(timeline_position_head: position + 1)
  end

  # A room answered by A with A's own reply on the timeline.
  def group_room
    conversation = conversation_answered_by(@agent)
    settle_turn!(conversation, "A, your view?", speaker: @creator, role: "user", answerer: @agent)
    settle_turn!(conversation, "A's view.", speaker: @creator, role: "assistant", answerer: @agent, kind: "direct_reply")
    conversation
  end

  def preview!(conversation, **overrides)
    result = Conversations::ContextEstimate.call(Conversations::ContextEstimate::Command.new(**{
      conversation: conversation.reload, acting_user: @poster, provider_id: "dev", model_ref: "mock-text",
      reasoning_effort: nil, request_options: nil, prompt: "and so?", history_max_entries: nil,
      history_token_budget_share: nil, reasoning_replay_mode: nil, inline: nil, render: true,
    }.merge(overrides)))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.rendered
  end

  # The send the preview modelled: the same poster, the same words, the
  # same addressee; its sealed request read as the debug door reads it.
  def send!(conversation, **overrides)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
      host: conversation, acting_user: @poster, kind: "direct_reply", role: "user",
      entries: [{ "text" => "and so?" }], visible_in_context: true, delivery_mode: "queue",
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: "mock-text",
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    variant = conversation.conversation_turns.order(:position).last.active_variant
    assert_equal "inference", variant.source
    ModelRequests::InputSource.accepted_entry_payloads(variant.model_invocation)
  end

  # A merged entry's texts, each segment its own part: the wire merges, nothing folds.
  def texts(entry) = entry.fetch("parts").map { |part| part["text"] }

  def assert_same_bytes(preview, sealed)
    assert_equal sealed.length, preview.entries.length
    sealed.zip(preview.entries).each_with_index do |(sealed_entry, previewed), index|
      assert_equal Nexus::CanonicalJson.encode(sealed_entry), Nexus::CanonicalJson.encode(previewed),
        "entry #{index}: the preview's bytes are the seal's"
    end
    assert_equal ContentBodies::Measure.call(sealed).bytes, preview.storage.bytes, "one measure"
  end

  test "1:1 under default: the rendered estimate is the sealed request, byte for byte" do
    conversation = conversation_answered_by(@agent)
    settle_turn!(conversation, "first question", speaker: @creator, role: "user", answerer: @agent)
    settle_turn!(conversation, "first answer", speaker: @agent, role: "assistant")

    preview = preview!(conversation)
    sealed = send!(conversation)

    assert_same_bytes(preview, sealed)
    assert_equal "default", preview.mechanism
    assert_equal %w[developer system user assistant user], sealed.map { |entry| entry["role"] },
      "the built-in order: the developer system_prompt, the system character, then the merged user item"
    assert_includes sealed[2].dig("parts", 0, "text"), "This is the poster.",
      "the author is the caller: the poster's persona, not the creator's"
  end

  test "1:1 under assembly: the template's order, the variable, memory and history — the same bytes" do
    declare!(@agent, "assembly", template: TEMPLATE)
    conversation = conversation_answered_by(@agent)
    settle_turn!(conversation, "first question", speaker: @creator, role: "user", answerer: @agent)
    settle_turn!(conversation, "first answer", speaker: @agent, role: "assistant")
    variables = { "scene" => "a rainy night" }

    preview = preview!(conversation, variables: variables)
    sealed = send!(conversation, context_options: { "variables" => variables })

    assert_same_bytes(preview, sealed)
    assert_equal "assembly", preview.mechanism
    assert_equal %w[developer user assistant user], sealed.map { |entry| entry["role"] }
    assert_equal ["Scene: a rainy night, with Fixture Agent.", "This is the poster."], texts(sealed[1]).first(2)
    assert_includes texts(sealed[1]).join("\n"), "gate code 4471"
    assert_equal %w[slot:system_prompt inline:1 slot:persona memory history input], preview.blocks.map(&:key)
  end

  # THE GROUP (must-fix #13): the stored answerer is A; the send is `to:
  # @peer`. The preview under `to:` compiles the peer's declaration — its
  # slot, its template — and envelopes A's earlier reply as a message to
  # the peer; without `to:` it would render A's, and the pair would be
  # false. Under `default` and under `assembly` on the peer.
  test "a group conversation addressed away from the stored answerer: the same bytes under both words" do
    peer = create_agent_member(display_name: "Peer", agent_identifier: "peer-agent")
    register!("system_prompt", "I am the peer.", on: { user: peer })
    conversation = group_room

    preview = preview!(conversation, answering_user_public_id: "@#{peer.handle}")
    sealed = send!(conversation, answering_user_public_id: "@#{peer.handle}")

    assert_same_bytes(preview, sealed)
    assert_equal "default", preview.mechanism
    assert_equal ["I am the peer.", "This is the room."], texts(sealed[0]),
      "the peer's slot leads, never the stored answerer's"
    assert_includes texts(sealed[1]).join("\n"), "<message from=\"@#{@agent.handle}\" kind=\"agent\" user=\"#{@agent.public_id}\">\nA's view.",
      "A's reply reads as a message to the peer, not as the peer's own words"
    assert_equal %w[system user], sealed.map { |entry| entry["role"] }
    unaddressed = preview!(conversation)
    assert_equal "I am the fixture agent.", unaddressed.entries[0].dig("parts", 0, "text"),
      "without `to:` the preview models the stored answerer's send"

    # The peer under `assembly`, on a fresh room (the first send's reply
    # is still running: a second head would wait behind it).
    declare!(peer, "assembly", template: TEMPLATE)
    conversation = group_room
    preview = preview!(conversation, answering_user_public_id: peer.public_id)
    sealed = send!(conversation, answering_user_public_id: peer.public_id)

    assert_same_bytes(preview, sealed)
    assert_equal "assembly", preview.mechanism
    assert_equal "I am the peer.", sealed[0].dig("parts", 0, "text")
    assert_match(/\AScene: an ordinary day, with Peer\./, sealed[1].dig("parts", 0, "text"))
  end

  test "the preview writes nothing" do
    conversation = conversation_answered_by(@agent)
    settle_turn!(conversation, "first question", speaker: @creator, role: "user", answerer: @agent)

    assert_no_difference([
      -> { ModelInvocation.count }, -> { ContentBody.count }, -> { ContentFragment.count },
      -> { ConversationTurn.count }, -> { ConversationInput.count },
      -> { conversation.conversation_event_items.count },
    ]) do
      preview!(conversation)
    end
  end

  test "an addressed peer's preset places history attachments identically in preview and send" do
    peer = create_agent_member(display_name: "Text peer", agent_identifier: "text-peer")
    declared = Users::DeclareConfiguration.call(user: peer, tool_definitions: [], approval_mode: nil,
      approval_rules: nil, prompt_mechanism: "default", prompt_template: nil, compaction_policy: nil,
      default_model: "dev/mock-text-only")
    assert_equal :declared, declared.outcome
    conversation = conversation_answered_by(@agent)
    picture = @account.content_uploads.create!(creating_user: @poster,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(Base64.decode64(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )), filename: "diagram.png", content_type: "image/png", identify: false
      ))
    input = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: conversation, acting_user: @poster, kind: "message", role: "user",
      entries: [{ "text" => "the diagram" }], attachments: [picture.public_id], visible_in_context: true,
      delivery_mode: "queue", context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil
    ))
    assert_predicate input, :accepted?, input.outcome.inspect
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)

    preview = preview!(conversation, answering_user_public_id: peer.public_id)
    sealed = send!(conversation, answering_user_public_id: peer.public_id)

    invocation = conversation.conversation_turns.order(:position).last.active_variant.model_invocation
    assert_equal "mock-text-only", invocation.model_ref
    assert_includes sealed.last.fetch("parts").map { |part| part["text"] }.join,
      "image content omitted: this model does not support image input"
    assert_same_bytes(preview, sealed)
  end

  # THE SUBMITTED TRIO IS THE LADDER'S LAST RUNG, on both doors. A caller
  # that addresses a peer declaring its own model names none, and the send
  # accepts it; a preview that refused the same call would refuse a send
  # that goes through — the one drift this door exists to prevent.
  test "an addressed peer's declared model answers a preview that names none" do
    peer = create_agent_member(display_name: "Preset peer", agent_identifier: "preset-peer")
    declared = Users::DeclareConfiguration.call(user: peer, tool_definitions: [], approval_mode: nil,
      approval_rules: nil, prompt_mechanism: "default", prompt_template: nil, compaction_policy: nil,
      default_model: "dev/mock-text")
    assert_equal :declared, declared.outcome
    conversation = conversation_answered_by(@agent)

    preview = preview!(conversation, answering_user_public_id: peer.public_id,
      provider_id: nil, model_ref: nil)
    sealed = send!(conversation, answering_user_public_id: peer.public_id,
      provider_id: nil, model_ref: nil)

    invocation = conversation.conversation_turns.order(:position).last.active_variant.model_invocation
    assert_equal "mock-text", invocation.model_ref
    assert_same_bytes(preview, sealed)
  end

  # Without an addressee there is no engine to supply one, so a blank
  # submitted model still refuses exactly as the drain would.
  test "a blank model with no addressee still refuses" do
    conversation = conversation_answered_by(@agent)
    result = Conversations::ContextEstimate.call(Conversations::ContextEstimate::Command.new(
      conversation: conversation, acting_user: @poster, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil, prompt: "and so?", history_max_entries: nil,
      history_token_budget_share: nil, reasoning_replay_mode: nil, inline: nil, render: true
    ))

    assert_equal :model_selection_missing, result.outcome
  end
end
