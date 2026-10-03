require "test_helper"
require "test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ExecutionDetailsRetentionTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  setup do
    @conversation = create_conversation!
    @seam = create_loop_backed_turn(conversation: @conversation, acting_user: @human,
      turn_status: "completed", variant_status: "completed", loop_status: "completed")
    @seam.agent_loop.update!(completed_at: 100.days.ago)
    @conversation.reload.update!(active_turn: nil)
    ContentBodies::Replace.call(owner: @seam.variant, role: "prompt", entries: [{ "text" => "question" }], seal: true)
    ContentBodies::Replace.call(owner: @seam.variant, role: "content", entries: [{ "text" => "answer" }], seal: true)
    @loop_path = "/agent_api/v1/workspaces/#{@workspace.public_id}/agent_loops/#{@seam.agent_loop.public_id}"
    Conversations::ExecutionDetails::Prune.call(account: @account, batch: 10)
  end

  test "the retained turn and loop explain expired detail without losing the answer" do
    get conversation_turns_path(@conversation), headers: auth
    assert_response :success
    variant = response.parsed_body.fetch("turns").sole.fetch("active_variant")
    assert_equal "question", variant.fetch("prompt_text")
    assert_equal "answer", variant.fetch("content")
    assert variant.fetch("details_pruned_at")
    assert_equal "unavailable", variant.dig("world", "status")

    get @loop_path, headers: auth
    assert_response :success
    loop = response.parsed_body.fetch("agent_loop")
    assert loop.fetch("details_pruned_at")
    assert_empty loop.fetch("tasks")
  end

  test "all old detail and execution mutation doors refuse explicitly" do
    %w[graph transcript phases tasks/missing tasks/missing/request].each do |path|
      get "#{@loop_path}/#{path}", headers: auth
      assert_expired
    end
    %w[start pause resume stop tasks/missing/retry tasks/missing/compact].each do |path|
      post "#{@loop_path}/#{path}", headers: auth, as: :json, params: {}
      assert_expired
    end
    post "#{@loop_path}/tasks", headers: auth(SecureRandom.uuid), as: :json,
      params: { steps: [{ model: { key: "new", model: { model: "dev/mock-text" }, prompt: "new" } }] }
    assert_expired
    assert_empty @seam.agent_loop.agent_loop_nodes.reload
  end

  test "regeneration and sealed request distinguish expired evidence from missing evidence" do
    path = "#{conversation_turns_path(@conversation)}/#{@seam.turn.public_id}"
    post "#{path}/regeneration", headers: auth, as: :json, params: {}
    assert_response :conflict
    assert_equal "execution_details_pruned", response.parsed_body.dig("error", "code")

    get request_path(@conversation, @seam.turn, @seam.variant), headers: auth
    assert_expired
  end

  private

    def assert_expired
      assert_response :gone
      assert_equal "execution_details_pruned", response.parsed_body.dig("error", "code")
    end
end
