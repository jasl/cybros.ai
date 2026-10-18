require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::VariantReadsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  setup do
    @conversation = create_conversation!
    @seam = create_run_backed_turn(conversation: @conversation, acting_user: @human,
      turn_status: "completed", variant_status: "completed", run_status: "completed")
    ContentBodies::Replace.call(owner: @seam.variant, role: "content", entries: [{ "text" => "Original answer" }], seal: true)
  end

  test "an exact candidate is stable after activation changes and preserves retained content" do
    replacement = @seam.turn.variants.create!(position: 1, source: "inference", status: "completed")
    ContentBodies::Replace.call(owner: replacement, role: "content", entries: [{ "text" => "Later answer" }], seal: true)
    @seam.turn.update!(active_variant: replacement)
    @seam.run.update!(details_pruned_at: Time.current)
    get variant_path, headers: auth
    assert_response :success
    value = response.parsed_body.fetch("variant")
    assert_equal @seam.variant.public_id, value.fetch("public_id")
    assert_equal "Original answer", value.fetch("content")
    assert_not value.fetch("active")
    assert_equal @seam.run.public_id, value.fetch("run_public_id")
    assert value.fetch("details_pruned_at")
    assert_equal({ "public_id" => @seam.turn.public_id, "inherited" => false }, response.parsed_body.fetch("turn"))
    @seam.variant.update!(deleted_at: Time.current)
    get variant_path, headers: auth
    assert_response :not_found
  end

  test "the point read cannot bypass hidden turns or its parent conversation" do
    other = create_conversation!
    get variant_path(conversation: other), headers: auth
    assert_response :not_found
    @seam.turn.update!(visibility: "hidden")
    get variant_path, headers: auth, params: { include_hidden: true }
    assert_response :not_found
  end

  test "inherited content follows the fork view without granting source execution access" do
    fork = Conversation.create!(workspace: @workspace, creating_user: users(:curator))
    fork.conversation_ancestries.create!(account: @workspace.account, ancestor_conversation: @conversation,
      depth: 1, boundary_position: @seam.turn.position)
    @conversation.update!(access_default: "none")
    @seam.turn.update!(visibility: "hidden")
    @token = create_access_token_fixture(user: users(:curator), name: "Fork reader")

    get variant_path(conversation: fork), headers: auth
    assert_response :success
    value = response.parsed_body.fetch("variant")
    assert_equal "Original answer", value.fetch("content")
    assert response.parsed_body.dig("turn", "inherited")
    assert_not value.key?("run_public_id")
    assert_not value.key?("rounds")
    assert_not_includes response.body, @seam.run.public_id
    override = fork.turn_overrides.create!(turn: @seam.turn, visibility: "hidden")
    get variant_path(conversation: fork), headers: auth
    assert_response :not_found
    override.update!(visibility: "visible", deleted_at: Time.current)
    get variant_path(conversation: fork), headers: auth
    assert_response :not_found
  end

  private

    def variant_path(conversation: @conversation)
      "#{turns_path(conversation)}/#{@seam.turn.public_id}/variants/#{@seam.variant.public_id}"
    end
end
