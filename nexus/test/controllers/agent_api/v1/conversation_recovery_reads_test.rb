require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationRecoveryReadsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  test "a known turn reads the canonical projection without paging through later history" do
    conversation = create_conversation!
    first = materialize_message(conversation, "first")
    get turn_path(conversation, first), headers: auth
    assert_response :success
    small = sql_count { get turn_path(conversation, first), headers: auth }
    expected = response.parsed_body.fetch("turn")

    21.times { |index| materialize_message(conversation, "later #{index}") }
    large = sql_count { get turn_path(conversation, first), headers: auth }
    assert_response :success
    assert_equal expected, response.parsed_body.fetch("turn")
    assert_operator large, :<=, small
    get conversation_turns_path(conversation), headers: auth, params: { limit: 1 }
    assert_equal expected, response.parsed_body.fetch("turns").sole
  end

  test "point reads and materializations respect hidden and concealed inherited views" do
    parent = create_conversation!
    first = materialize_message(parent, "first")
    boundary = materialize_message(parent, "boundary")
    post conversation_forks_path(parent), headers: auth("fork"), as: :json,
      params: { fork: { turn_public_id: boundary.public_id } }
    assert_response :created
    child = Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))

    patch turn_path(parent, first), headers: auth, as: :json, params: { turn: { visibility: "hidden" } }
    assert_response :success
    get turn_path(child, first), headers: auth
    assert_response :success
    assert_equal true, response.parsed_body.dig("turn", "inherited")
    assert_equal "visible", response.parsed_body.dig("turn", "visibility")
    get materialization_path(child, first.input_public_id), headers: auth
    assert_response :success
    assert_equal first.active_variant.public_id, response.parsed_body.dig("materialization", "variant_public_id")

    patch turn_path(child, first), headers: auth, as: :json, params: { turn: { visibility: "hidden" } }
    assert_response :success
    [turn_path(child, first), materialization_path(child, first.input_public_id)].each do |path|
      get path, headers: auth
      assert_response :not_found
      get path, headers: auth, params: { include_hidden: true }
      assert_response :success
    end

    patch turn_path(child, first), headers: auth, as: :json, params: { turn: { concealed: true } }
    assert_response :success
    [turn_path(child, first), materialization_path(child, first.input_public_id)].each do |path|
      get path, headers: auth, params: { include_hidden: true }
      assert_response :not_found
    end
  end

  test "materialization survives queue and event removal and never selects a later edit" do
    conversation = create_conversation!
    turn = materialize_message(conversation, "original")
    original = turn.active_variant
    assert_not ConversationInput.exists?(public_id: turn.input_public_id)
    ConversationEventItem.where(host: conversation).delete_all

    post "#{turn_path(conversation, turn)}/edit", headers: auth, as: :json,
      params: { edit: { text: "edited" } }
    assert_response :success
    edited_id = response.parsed_body.dig("variant", "public_id")
    assert_not_equal original.public_id, edited_id
    get materialization_path(conversation, turn.input_public_id), headers: auth
    assert_response :success
    assert_equal({
      "input_public_id" => turn.input_public_id, "turn_public_id" => turn.public_id,
      "variant_public_id" => original.public_id, "run_public_id" => nil,
    }, response.parsed_body.fetch("materialization"))

    patch "#{turn_path(conversation, turn)}/variants/#{original.public_id}", headers: auth, as: :json,
      params: { variant: { concealed: true } }
    assert_response :success
    get materialization_path(conversation, turn.input_public_id), headers: auth, params: { include_hidden: true }
    assert_response :not_found
  end

  test "pending and foreign inputs have no materialization and both reads retain conversation access" do
    conversation = create_conversation!
    post conversation_inputs_path(conversation), headers: auth("pending"), as: :json,
      params: { input: { text: "pending" } }
    assert_response :accepted
    input_id = response.parsed_body.dig("input", "public_id")
    get materialization_path(conversation, input_id), headers: auth
    assert_response :not_found
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    turn = conversation.conversation_turns.sole
    other = create_conversation!
    [turn_path(other, turn), materialization_path(other, input_id)].each do |path|
      get path, headers: auth
      assert_response :not_found
    end

    conversation.reload.update!(access_default: "none")
    token = create_access_token_fixture(user: users(:curator), name: "Other reader")
    [turn_path(conversation, turn), materialization_path(conversation, input_id)].each do |path|
      get path, headers: { "Authorization" => "Bearer #{token.secret}" }, params: { include_hidden: true }
      assert_response :not_found
    end
  end

  test "one point read carries the running regeneration beside the displayed answer" do
    conversation = create_conversation!
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
    grow!(seam.agent_run, model("r1", "prompt" => "go"))
    ContentBodies::Replace.call(owner: seam.variant, role: "prompt", entries: [{ "text" => "question" }],
      readable_text: "question", seal: true)
    get turn_path(conversation, seam.turn), headers: auth
    assert_response :success
    assert_not response.parsed_body.fetch("turn").key?("running_variant")
    AgentRuns::Transition.agent_run(seam.agent_run, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call

    post "#{turn_path(conversation, seam.turn)}/regeneration", headers: auth("regenerate"), as: :json,
      params: { regeneration: { model: { model: "dev/mock-text" } } }
    assert_response :accepted
    candidate = response.parsed_body.fetch("variant")
    assert_equal seam.variant.public_id, candidate.fetch("origin_variant_public_id")
    get turn_path(conversation, seam.turn), headers: auth
    assert_response :success
    projection = response.parsed_body.fetch("turn")
    assert_equal seam.variant.public_id, projection.dig("active_variant", "public_id")
    assert_equal candidate, projection.fetch("running_variant")
    get conversation_turns_path(conversation), headers: auth
    assert_equal projection, response.parsed_body.fetch("turns").sole
  end

  test "direct inference materialization gives the original candidate without waiting for execution" do
    conversation = create_conversation!
    post conversation_inputs_path(conversation), headers: auth("reply"), as: :json,
      params: { input: { kind: "direct_reply", text: "question", model: { model: "dev/mock-text" } } }
    assert_response :accepted
    input_id = response.parsed_body.dig("input", "public_id")
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    turn = conversation.conversation_turns.sole
    event = conversation.conversation_event_items.find_by!(item_type: "input_materialized").payload
    get materialization_path(conversation, input_id), headers: auth
    assert_response :success
    assert_equal({
      "input_public_id" => input_id, "turn_public_id" => turn.public_id,
      "variant_public_id" => turn.active_variant.public_id, "run_public_id" => nil,
    }, response.parsed_body.fetch("materialization"))
    assert_equal response.parsed_body.fetch("materialization"), event.except("queue_position")
  end

  private

    def materialize_message(conversation, text)
      post conversation_inputs_path(conversation), headers: auth(SecureRandom.uuid), as: :json,
        params: { input: { text: text } }
      assert_response :accepted
      perform_enqueued_jobs only: Conversations::Inputs::DrainJob
      conversation.conversation_turns.order(:position).last
    end

    def turn_path(conversation, turn) = "#{conversation_turns_path(conversation)}/#{turn.public_id}"
    def materialization_path(conversation, input_id) = "#{conversation_inputs_path(conversation)}/#{input_id}/materialization"
end
