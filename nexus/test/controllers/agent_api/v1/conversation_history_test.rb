require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationHistoryTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  test "history filters before pagination across browsable workspaces and retains workspace locators" do
    second = Workspace.create!(account: @account, creator: @human, owner: @human,
      name: "History", access_mode: :private, state: :archived)
    first = history_row(@workspace)
    last = history_row(second, archived_at: Time.current)
    history_row(@workspace, metadata: { "application_bot" => "another" })
    history_row(@workspace, answering_user: @human)
    history_row(@workspace, side: true)
    history_row(@workspace, parent_conversation_public_id: SecureRandom.uuid_v7)
    history_row(@workspace, tombstoned_at: Time.current)
    history_row(workspaces(:personal))
    deleted = Workspace.create!(account: @account, creator: @human, owner: @human,
      name: "Gone", access_mode: :private, state: :deleted)
    history_row(deleted)

    options = { answering_user_public_id: users(:agent).public_id,
      metadata_key: "application_bot", metadata_value: "one", order: "asc", limit: 1 }
    get "/agent_api/v1/conversations", headers: auth, params: options
    assert_response :success
    assert_equal [first.public_id], listed_ids
    assert_equal @workspace.public_id, response.parsed_body.fetch("conversations").first.fetch("workspace_public_id")
    cursor = response.parsed_body.dig("pagination", "next_after")
    assert cursor
    get "/agent_api/v1/conversations", headers: auth, params: options.merge(after: cursor)
    assert_response :success
    assert_equal [last.public_id], listed_ids
    assert_equal second.public_id, response.parsed_body.fetch("conversations").first.fetch("workspace_public_id")

    get "/agent_api/v1/conversations", headers: auth, params: options.except(:limit).merge(archived: "0")
    assert_equal [first.public_id], listed_ids
    get "/agent_api/v1/conversations", headers: auth, params: options.except(:limit).merge(archived: "1")
    assert_equal [last.public_id], listed_ids
  end

  test "history applies conversation visibility and does not query once per workspace" do
    first = history_row(@workspace)
    get "/agent_api/v1/conversations", headers: auth
    one = sql_count { get "/agent_api/v1/conversations", headers: auth }
    second = Workspace.create!(account: @account, creator: @human, owner: @human, name: "Another")
    other = history_row(second)
    concealed = history_row(second, creating_user: users(:owner), access_default: "none")
    refute concealed.readable_by?(@human)
    two = sql_count { get "/agent_api/v1/conversations", headers: auth }
    assert_response :success
    assert_equal [first.public_id, other.public_id].sort, listed_ids.sort
    assert_equal one, two
  end

  test "workspace working and archived lists filter answerer before their page and exclude orphaned children" do
    selected = history_row(@workspace)
    history_row(@workspace, answering_user: @human)
    history_row(@workspace, parent_conversation_public_id: SecureRandom.uuid_v7)
    get conversations_path, headers: auth, params: { answering_user_public_id: users(:agent).public_id, limit: 1 }
    assert_equal [selected.public_id], listed_ids
    selected.update!(archived_at: Time.current)
    get archived_conversations_path, headers: auth, params: { answering_user_public_id: users(:agent).public_id, limit: 1 }
    assert_equal [selected.public_id], listed_ids
  end

  test "history rejects incomplete metadata filters and unknown archive flags" do
    [{ metadata_key: "application_bot" }, { metadata_value: "one" }, { archived: "maybe" }].each do |options|
      get "/agent_api/v1/conversations", headers: auth, params: options
      assert_response :bad_request
    end
  end

  private

    def history_row(workspace, **attributes)
      Conversation.create!(workspace: workspace, creating_user: @human, answering_user: users(:agent),
        metadata: { "application_bot" => "one" }, **attributes)
    end

    def listed_ids = response.parsed_body.fetch("conversations").pluck("public_id")
end
