require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationHiddenTurnsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  test "an explicit hidden read discovers a held execution after its active pointer clears" do
    conversation = create_conversation!
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
    patch "#{conversation_turns_path(conversation)}/#{seam.turn.public_id}", headers: auth, as: :json,
      params: { turn: { visibility: "hidden" } }
    assert_response :success

    AgentRuns::Transition.agent_run(seam.agent_run, status: "needs_attention",
      attention_reason: "halt_failure")
    Conversations::Turns::Converge.call(conversation_id: conversation.id, agent_run_id: seam.agent_run.id)
    assert_equal "failed", seam.turn.reload.status
    assert_nil conversation.reload.active_turn_id

    get conversation_turns_path(conversation), headers: auth
    assert_response :success
    assert_empty response.parsed_body.fetch("turns")
    get conversation_turns_path(conversation), headers: auth, params: { include_hidden: false }
    assert_response :success
    assert_empty response.parsed_body.fetch("turns")

    get conversation_turns_path(conversation), headers: auth, params: { include_hidden: true }
    assert_response :success
    turns = response.parsed_body.fetch("turns")
    assert_equal 1, turns.length
    turn = turns.sole
    assert_equal seam.turn.public_id, turn.fetch("public_id")
    assert_equal "hidden", turn.fetch("visibility")
    assert_equal "failed", turn.fetch("status")
    assert_equal "direct_reply", turn.fetch("kind")
    assert_not turn.fetch("inherited")
    assert_equal seam.agent_run.public_id, turn.dig("active_variant", "run_public_id")
  end

  test "hidden windows use inherited view overrides and still exclude concealed turns" do
    parent = create_conversation!
    %w[first hidden concealed boundary].each_with_index do |text, index|
      post conversation_inputs_path(parent), headers: auth("hidden-#{index}"), as: :json,
        params: { input: { text: text } }
      assert_response :accepted
    end
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    first, hidden, concealed, boundary = parent.conversation_turns.order(:position).to_a
    post conversation_forks_path(parent), headers: auth("hidden-fork"), as: :json,
      params: { fork: { turn_public_id: boundary.public_id } }
    assert_response :created
    child = Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))
    child_boundary = child.conversation_turns.sole

    patch "#{conversation_turns_path(parent)}/#{first.public_id}", headers: auth, as: :json,
      params: { turn: { visibility: "hidden" } }
    assert_response :success
    patch "#{conversation_turns_path(child)}/#{hidden.public_id}", headers: auth, as: :json,
      params: { turn: { visibility: "hidden" } }
    assert_response :success
    patch "#{conversation_turns_path(child)}/#{concealed.public_id}", headers: auth, as: :json,
      params: { turn: { concealed: true } }
    assert_response :success

    get conversation_turns_path(child), headers: auth
    assert_response :success
    assert_equal [first.public_id, child_boundary.public_id], response.parsed_body.fetch("turns").pluck("public_id")

    get conversation_turns_path(child), headers: auth, params: { include_hidden: true }
    assert_response :success
    turns = response.parsed_body.fetch("turns")
    assert_equal [first.public_id, hidden.public_id, child_boundary.public_id], turns.pluck("public_id")
    assert_equal %w[visible hidden visible], turns.pluck("visibility")
    assert_equal [true, true, false], turns.pluck("inherited")

    get conversation_turns_path(child), headers: auth,
      params: { include_hidden: true, after_position: first.position, limit: 1 }
    assert_response :success
    assert_equal [hidden.public_id], response.parsed_body.fetch("turns").pluck("public_id")
    assert_equal hidden.position, response.parsed_body.dig("pagination", "after_position")
  end

  test "including hidden turns preserves Conversation access rules" do
    conversation = create_conversation!
    conversation.update!(access_default: "none")
    other_token = create_access_token_fixture(user: users(:curator), name: "Other reader")

    get conversation_turns_path(conversation),
      headers: { "Authorization" => "Bearer #{other_token.secret}" }, params: { include_hidden: true }

    assert_response :not_found
  end
end
