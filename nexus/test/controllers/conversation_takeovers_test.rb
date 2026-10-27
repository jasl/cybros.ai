require "test_helper"

class ConversationTakeoversTest < ActionDispatch::IntegrationTest
  include AgentMembershipTestHelper
  setup do
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @parent = Conversation.create!(workspace: @workspace, creating_user: @agent, answering_user: @agent)
    @child = Conversation.create!(workspace: @workspace, creating_user: @agent, answering_user: @agent,
      parent_conversation: @parent, parent_conversation_public_id: @parent.public_id, spawn_label: "research")
    @headers = { "Authorization" => "Bearer #{create_access_token_fixture(user: @human, name: "takeover").secret}" }
  end

  test "Human member bearer takes over once and member readers retain provenance in the root list" do
    post takeover_path, params: { origin: "agent", taken_over_by_public_id: @agent.public_id }, as: :json, headers: @headers
    assert_response :success
    row = response.parsed_body.fetch("conversation")
    assert_equal @child.public_id, row.fetch("public_id")
    assert_equal @parent.public_id, row.dig("parent", "public_id")
    assert_equal @human.public_id, row.fetch("taken_over_by_public_id")
    assert row.fetch("taken_over_at")
    assert_equal 1, @child.event_items.where(item_type: "conversation_taken_over").count
    stamp = @child.reload.taken_over_at
    post takeover_path, as: :json, headers: @headers
    assert_response :success
    assert_equal stamp, @child.reload.taken_over_at
    assert_equal 1, @child.event_items.where(item_type: "conversation_taken_over").count

    headers = { "Authorization" => "Bearer #{create_access_token_fixture(user: @human, name: "takeover-read").secret}" }
    get "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations", headers: headers
    assert_response :success
    assert_includes response.parsed_body.fetch("conversations").pluck("public_id"), @child.public_id
    get "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{@parent.public_id}/children", headers: headers
    assert_response :success
    refute_includes response.parsed_body.fetch("conversations").pluck("public_id"), @child.public_id
    assert Conversations::Archive.call(conversation: @parent).accepted?
    refute @child.reload.archived?
    assert Conversations::Archive.call(conversation: @child).accepted?
  end

  test "read access refuses and even the owner cannot take over concealed work" do
    @child.update!(access_default: "read")
    post takeover_path, as: :json, headers: @headers
    assert_response :forbidden
    assert_nil @child.reload.taken_over_at
    @child.update!(access_default: "none")
    @headers = { "Authorization" => "Bearer #{create_access_token_fixture(user: users(:owner), name: "owner-takeover").secret}" }
    post takeover_path, as: :json, headers: @headers
    assert_response :not_found
    assert_nil @child.reload.taken_over_at
  end

  test "Agent bearer cannot impersonate a Human through body fields" do
    connection = connect_agent_session(steward: @agent.steward, agent_identifier: @agent.agent_identifier)
    post takeover_path, params: { origin: "person", acting_user_public_id: @human.public_id },
      headers: { "Authorization" => "Bearer #{connection.access_secret}" }, as: :json
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
    assert_nil @child.reload.taken_over_at
  end

  test "missing and wrong-plane credentials cannot borrow a browser Session" do
    sign_in_as @human
    platform = create_access_token_fixture(user: @human, name: "platform-takeover", plane: :platform)
    transport = connect_agent_session(steward: @agent.steward, agent_identifier: @agent.agent_identifier)
    [nil, platform.secret, transport.executor_access_secret].each do |credential|
      post takeover_path, as: :json, headers: credential ? { "Authorization" => "Bearer #{credential}" } : {}
      assert_response :unauthorized
      assert_nil @child.reload.taken_over_at
    end
  end

  test "wrong Workspace conceals a valid child and domain refusals retain conflict status" do
    wrong = Workspace.create!(account: @human.account, owner: @human, creator: @human, name: "Other")
    post "/agent_api/v1/workspaces/#{wrong.public_id}/conversations/#{@child.public_id}/takeover", as: :json, headers: @headers
    assert_response :not_found
    post "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{@parent.public_id}/takeover", as: :json, headers: @headers
    assert_response :conflict
    assert_equal "not_subagent", response.parsed_body.dig("error", "code")
    @child.update!(archived_at: Time.current)
    post takeover_path, as: :json, headers: @headers
    assert_response :conflict
    assert_equal "conversation_archived", response.parsed_body.dig("error", "code")
    assert_nil @child.reload.taken_over_at
  end

  test "a released label can name a new follower without changing birth provenance" do
    post takeover_path, as: :json, headers: @headers
    assert_response :success
    replacement = Conversation.create!(workspace: @workspace, creating_user: @agent, answering_user: @agent,
      parent_conversation: @parent, parent_conversation_public_id: @parent.public_id, spawn_label: "research")
    resolution = Conversations::ConversationAddress.resolve(sender_conversation: @parent, sender: @agent, address: "research")
    assert_equal replacement, resolution.conversation
    assert_equal "research", @child.reload.spawn_label
    assert_equal @parent.public_id, @child.parent_conversation_public_id
  end

  private

    def takeover_path
      "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{@child.public_id}/takeover"
    end
end
