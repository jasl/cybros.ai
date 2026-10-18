require "test_helper"
require_relative "../../../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::Workspaces::Conversations::UpdatesTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  test "a stale update preserves a newer title and metadata" do
    conversation = create_conversation!(title: "Initial")
    version = conversation.lock_version
    patch conversation_path(conversation), headers: auth, as: :json,
      params: { conversation: { title: "Manual title", metadata: { topic: "manual" }, lock_version: version } }
    assert_response :success

    patch conversation_path(conversation), headers: auth, as: :json,
      params: { conversation: { title: "Late title", metadata: { topic: "late" }, lock_version: version } }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
    assert_equal "Manual title", conversation.reload.title
    assert_equal({ "topic" => "manual" }, conversation.metadata)
  end

  test "reads expose the edit version and fresh partial edits retain other fields" do
    conversation = create_conversation!(title: "Initial")
    get conversation_path(conversation), headers: auth
    version = response.parsed_body.fetch("conversation").fetch("lock_version")

    patch conversation_path(conversation), headers: auth, as: :json,
      params: { conversation: { metadata: { topic: "planning" }, lock_version: version } }
    assert_response :success
    detail = response.parsed_body.fetch("conversation")
    assert_equal "Initial", detail.fetch("title")
    assert_equal version + 1, detail.fetch("lock_version")

    patch conversation_path(conversation), headers: auth, as: :json,
      params: { conversation: { title: nil, lock_version: detail.fetch("lock_version") } }
    assert_response :success
    assert_nil response.parsed_body.dig("conversation", "title")
    assert_equal({ "topic" => "planning" }, conversation.reload.metadata)

    get conversations_path, headers: auth
    assert_equal conversation.lock_version, response.parsed_body.fetch("conversations").sole.fetch("lock_version")
  end

  test "missing or malformed edit versions refuse before changing the row" do
    conversation = create_conversation!(title: "Initial")
    [nil, -1, "invalid", 2_147_483_648].each do |version|
      fields = { title: "Changed" }
      fields[:lock_version] = version unless version.nil?
      patch conversation_path(conversation), headers: auth, as: :json, params: { conversation: fields }
      assert_response :bad_request
      assert_equal version.nil? ? "parameter_missing" : "parameter_invalid", response.parsed_body.dig("error", "code")
      assert_equal "Initial", conversation.reload.title
    end
  end

  test "invalid edits retain the version and an unchanged edit accepts its current version" do
    conversation = create_conversation!(title: "Initial")
    version = conversation.lock_version
    patch conversation_path(conversation), headers: auth, as: :json,
      params: { conversation: { title: "x" * 256, lock_version: version } }
    assert_response :unprocessable_entity
    assert_equal version, conversation.reload.lock_version
    assert_equal "Initial", conversation.title

    patch conversation_path(conversation), headers: auth, as: :json,
      params: { conversation: { title: "Initial", lock_version: version } }
    assert_response :success
    assert_equal version, response.parsed_body.dig("conversation", "lock_version")

    patch conversation_path(conversation), headers: auth, as: :json,
      params: { conversation: { lock_version: version } }
    assert_response :unprocessable_entity
  end
end
