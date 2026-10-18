require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationFieldsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  setup do
    @conversation = create_conversation!
    @turn = @conversation.turns.create!(position: 0, kind: "message", role: "user", status: "completed",
      speaker: Speakers::Resolve.member(account: @account, user: @human), control_owner_user: @human)
    @variant = @turn.variants.create!(position: 0, status: "completed", source: "manual")
    @turn.update!(active_variant: @variant)
    @conversation.update!(timeline_position_head: 1)
  end

  test "a body hit opens the original candidate and its literal neighborhood after activation changes" do
    ContentBodies::Replace.call(owner: @variant, role: "content",
      entries: [{ "text" => "前言" * 10_000 + " needle original answer" }], seal: true)
    match = search("needle")
    replacement = @turn.variants.create!(position: 1, status: "completed", source: "manual")
    ContentBodies::Replace.call(owner: replacement, role: "content", entries: [{ "text" => "replacement" }], seal: true)
    @turn.update!(active_variant: replacement)
    @variant.update!(details_pruned_at: Time.current)

    get field_path, headers: auth, params: { location: match.fetch("location") }
    assert_response :success
    body = response.parsed_body
    assert_equal @variant.public_id, body.fetch("variant_public_id")
    assert_includes body.fetch("text"), "needle original answer"
    assert_not_includes body.fetch("text"), "replacement"
    assert_equal Nexus::Contract.send(:history).fetch("field_fixture").keys.sort, body.keys.sort
    assert_not body.key?("run_public_id")
    assert_not body.key?("configuration")
  end

  test "later accepted steers locate inside a huge text part and continue after retention" do
    entries = 24.times.map { |index| { "text" => "earlier #{index}" } }
    entries << { "parts" => [{ "type" => "text", "text" => "first part" },
      { "type" => "text", "text" => "前言🙂" * 8_000 + " needle " + "后文🙂" * 6_000 }] }
    entries << { "text" => "final steer" }
    ContentBodies::Replace.archive(owner: @variant, role: "steers", entries: entries)
    match = search("needle")
    point = Conversations::History::Location.decode(match.fetch("location"))
    assert_equal 24, point.fetch(:entry_position)
    assert_equal 1, point.fetch(:part_index)
    assert_operator point.fetch(:character_offset), :>, 20_000
    get field_path("steers"), headers: auth, params: { location: match.fetch("location") }
    assert_response :success
    assert_includes response.parsed_body.fetch("text"), "needle"
    assert_operator response.parsed_body.fetch("text").bytesize, :<=, 16_384
    after = response.parsed_body.dig("pagination", "next_after")
    assert after
    get field_path("steers"), headers: auth, params: { after: after }
    assert_response :success
    assert_not_includes response.parsed_body.fetch("text"), "needle"
    assert_not_equal after, response.parsed_body.dig("pagination", "next_after")
  end

  test "every continuation rechecks current visibility and the exact candidate" do
    ContentBodies::Replace.call(owner: @variant, role: "content", entries: [{ "text" => "word " * 5_000 }], seal: true)
    get field_path, headers: auth
    after = response.parsed_body.dig("pagination", "next_after")
    replacement = @turn.variants.create!(position: 1, status: "completed", source: "manual")
    @turn.update!(active_variant: replacement)
    result = Conversations::Variants::SetViewState.call(Conversations::Variants::SetViewState::Command.new(
      conversation: @conversation, turn_public_id: @turn.public_id, variant_public_id: @variant.public_id,
      acting_user: @human, concealed: true))
    assert result.accepted?
    get field_path, headers: auth, params: { after: after }
    assert_response :not_found
    result = Conversations::Variants::SetViewState.call(Conversations::Variants::SetViewState::Command.new(
      conversation: @conversation, turn_public_id: @turn.public_id, variant_public_id: @variant.public_id,
      acting_user: @human, concealed: false))
    assert result.accepted?
    @turn.update!(visibility: "hidden")
    get field_path, headers: auth
    assert_response :not_found
    @turn.update!(visibility: "visible")
    @conversation.update!(access_default: "none")
    other = create_access_token_fixture(user: users(:curator), name: "Other field reader")
    get field_path, headers: { "Authorization" => "Bearer #{other.secret}" }, params: { after: after }
    assert_response :not_found
  end

  test "readable inherited text does not expose source execution and obeys the destination overlay" do
    ContentBodies::Replace.call(owner: @variant, role: "content", entries: [{ "text" => "inherited field" }], seal: true)
    fork = Conversation.create!(workspace: @workspace, creating_user: users(:curator))
    ConversationAncestry.create!(account: @account, conversation: fork,
      ancestor_conversation: @conversation, depth: 1, boundary_position: @turn.position)
    @conversation.update!(access_default: "none")
    other = create_access_token_fixture(user: users(:curator), name: "Fork field reader")
    headers = { "Authorization" => "Bearer #{other.secret}" }
    path = field_path("content", conversation: fork)
    get path, headers: headers
    assert_response :success
    assert response.parsed_body.fetch("inherited")
    assert_equal "inherited field", response.parsed_body.fetch("text")
    assert_not_includes response.body, @conversation.public_id
    fork.turn_overrides.create!(turn: @turn, visibility: "visible", deleted_at: Time.current)
    get path, headers: headers
    assert_response :not_found
  end

  test "empty fields and malformed field cursors are explicit" do
    get field_path("prompt"), headers: auth
    assert_response :success
    assert_equal "", response.parsed_body.fetch("text")
    assert_nil response.parsed_body.dig("pagination", "next_after")
    get field_path("reasoning"), headers: auth
    assert_response :bad_request
    get field_path, headers: auth, params: { location: "broken" }
    assert_response :bad_request
    get field_path, headers: auth, params: { location: "one", after: "two" }
    assert_response :bad_request
  end

  test "workspace access and effective history are rechecked for saved field URLs" do
    ContentBodies::Replace.call(owner: @variant, role: "content", entries: [{ "text" => "saved answer" }], seal: true)
    get field_path, headers: auth
    assert_response :success
    @workspace.update!(access_mode: "private")
    get field_path, headers: auth
    assert_response :not_found
    @workspace.update!(access_mode: "account_wide")
    unrelated = create_conversation!
    get field_path("content", conversation: unrelated), headers: auth
    assert_response :not_found
    @conversation.update!(tombstoned_at: Time.current)
    get field_path, headers: auth
    assert_response :not_found
  end

  private

    def field_path(field = "content", conversation: @conversation)
      "#{conversation_path(conversation)}/turns/#{@turn.public_id}/variants/#{@variant.public_id}/fields/#{field}"
    end

    def search(query)
      get "/agent_api/v1/workspaces/#{@workspace.public_id}/conversation_search", headers: auth, params: { query: query }
      assert_response :success
      response.parsed_body.fetch("matches").sole
    end
end
