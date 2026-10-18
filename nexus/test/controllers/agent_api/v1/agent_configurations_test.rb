require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::AgentConfigurationsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  test "input create captures the declaration and intent and includes both in its idempotency envelope" do
    conversation = agent_conversation
    payload = { input: { kind: "direct_reply", text: "Do the work", agent_configuration: declaration("Captured"),
      model_selection: { source: "explicit", model: "dev/mock-text", constraint: "route", alternatives: [] },
      fallback_models: ["dev/mock-priced"] } }
    post inputs_path(conversation), headers: auth("capture"), as: :json, params: payload
    assert_response :accepted
    public_id = response.parsed_body.dig("input", "public_id")
    input = conversation.inputs.find_by!(public_id: public_id)
    assert_equal "Captured", input.agent_configuration.system_prompt.content
    assert_equal "explicit", input.model_selection.source
    assert_equal ["dev/mock-priced"], input.fallback_models
    assert_equal ["dev", "mock-text"], [input.provider_id, input.model_ref]

    post inputs_path(conversation), headers: auth("capture"), as: :json, params: payload
    assert_response :accepted
    assert_equal public_id, response.parsed_body.dig("input", "public_id")
    payload[:input][:agent_configuration][:system_prompt][:content] = "Different"
    post inputs_path(conversation), headers: auth("capture"), as: :json, params: payload
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
    assert_equal "Captured", input.reload.agent_configuration.system_prompt.content
  end

  test "queued input update replaces the execution declaration and can disable its ordered fallback list" do
    conversation = agent_conversation
    post inputs_path(conversation), headers: auth("queued"), as: :json,
      params: { input: { kind: "direct_reply", text: "Question", agent_configuration: declaration("First"),
        fallback_models: ["dev/mock-priced"] } }
    assert_response :accepted
    input = conversation.inputs.sole

    patch "#{inputs_path(conversation)}/#{input.public_id}", headers: auth, as: :json,
      params: { input: { expected_lock_version: input.lock_version, agent_configuration: declaration("Replacement"),
        model_selection: { source: "explicit", model: "dev/mock-text", constraint: "route" }, fallback_models: [] } }
    assert_response :success
    assert_equal "Replacement", input.reload.agent_configuration.system_prompt.content
    assert_equal "route", input.model_selection.constraint
    assert_equal [], input.fallback_models
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    variant = conversation.turns.last.active_variant
    assert_equal "Replacement", variant.agent_configuration.system_prompt.content
    assert_equal "explicit", variant.model_selection.source
    assert_equal [], variant.fallback_models
    get "#{conversation_path(conversation)}/turns/#{variant.turn.public_id}", headers: auth
    assert_response :success
    assert_equal "explicit", response.parsed_body.dig("turn", "active_variant", "model_selection", "source")
    assert_equal [], response.parsed_body.dig("turn", "active_variant", "fallback_models")
  end

  test "context preview reads the supplied declaration without changing profile or creating execution" do
    conversation = agent_conversation
    counts = [Input.count, Turn.count, ModelInvocation.count]
    post conversation_context_estimate_path(conversation), headers: auth, as: :json,
      params: { context_estimate: { prompt: "Question", render: true, agent_configuration: declaration("Preview instructions"),
        model_selection: { source: "explicit", model: "dev/mock-text", constraint: "route" }, fallback_models: [] } }
    assert_response :success
    assert_includes response.parsed_body.dig("context_estimate", "entries").to_json, "Preview instructions"
    assert_equal counts, [Input.count, Turn.count, ModelInvocation.count]
    assert_nil users(:agent).prompt_documents.find_by(slot: "system_prompt")
  end

  test "an invalid inline declaration fails without accepting any input" do
    conversation = agent_conversation
    invalid = declaration("Bad tools").merge(kernel_tools: ["nexus.memory.read"], approval_mode: nil)
    assert_no_difference -> { Input.count } do
      post inputs_path(conversation), headers: auth("invalid"), as: :json,
        params: { input: { kind: "direct_reply", text: "Question", agent_configuration: invalid } }
    end
    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
  end

  test "addressing another Agent on a declared child uses that Agent in send and preview" do
    agent = users(:agent)
    other = User.create!(account: @account, kind: "agent", display_name: "Other", handle: "declared-other",
      steward: @human, agent_identifier: "declared-other", default_model: "dev/mock-unmetered", fallback_models: [])
    PromptDocuments::Write.call(anchor: { user: other }, slot: "system_prompt", content: "Other Agent instructions.")
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent,
      agent_configuration: declaration("Child role instructions."),
      model_selection: ModelSelectionIntent.inherited("dev/mock-text"), fallback_models: ["dev/mock-priced"])

    post conversation_context_estimate_path(conversation), headers: auth, as: :json,
      params: { context_estimate: { prompt: "Question", render: true, answering_user_public_id: other.public_id } }
    assert_response :success
    rendered = response.parsed_body.dig("context_estimate", "entries").to_json
    assert_includes rendered, "Other Agent instructions."
    assert_not_includes rendered, "Child role instructions."

    post inputs_path(conversation), headers: auth("other"), as: :json,
      params: { input: { kind: "direct_reply", text: "Question", answering_user_public_id: other.public_id } }
    assert_response :accepted
    input = conversation.inputs.sole
    assert_equal other, input.answering_user
    assert_equal ["dev", "mock-unmetered"], [input.provider_id, input.model_ref]
    assert_nil input.agent_configuration
    assert_nil input.fallback_models
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    variant = conversation.turns.last.active_variant
    assert_equal "Other Agent instructions.", variant.agent_configuration.system_prompt.content
    assert_equal [], variant.fallback_models
  end

  private

    def agent_conversation
      Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent))
    end

    def declaration(text)
      { default_model: "dev/mock-text", fallback_models: [], prompt_mechanism: "default",
        tool_definitions: [], system_prompt: { content: text, role: "system" } }
    end
end
