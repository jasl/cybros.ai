require "test_helper"

class AgentAPI::V1::Workspaces::MessagingTest < ActionDispatch::IntegrationTest
  include AgentMembershipTestHelper

  setup do
    @workspace = workspaces(:shared)
    @owner = create_access_token_fixture(user: users(:owner), name: "Messaging owner")
    @member = create_access_token_fixture(user: users(:member), name: "Messaging reader")
    @sender = users(:agent)
    @recipient = create_agent_member(steward: users(:owner), agent_identifier: "api-messaging-target")
  end

  test "the shared contract request replaces the policy and both doors return its projection" do
    contract = Nexus::Contract.pack.fetch("workspaces.json")
    request = contract.fetch("valid_messaging_request").deep_dup
    request.fetch("messaging")["agents"] = [agent_policy]
    request.fetch("messaging")["lock_version"] = @workspace.lock_version

    put path, headers: bearer(@owner), params: request, as: :json

    assert_response :success
    document = response.parsed_body.fetch("messaging")
    assert_equal contract.fetch("messaging_projection").sort, document.keys.sort
    assert_equal contract.fetch("messaging_agent_projection").sort, document.fetch("agents").sole.keys.sort
    assert_equal [agent_policy], document.fetch("agents")
    assert_equal @workspace.reload.lock_version, document.fetch("lock_version")

    get path, headers: bearer(@member)

    assert_response :success
    assert_equal document, response.parsed_body.fetch("messaging")
  end

  test "the default read and an explicit empty replacement keep messaging unrestricted" do
    get path, headers: bearer(@member)

    assert_response :success
    assert_equal({ "agents" => [], "lock_version" => @workspace.lock_version }, response.parsed_body.fetch("messaging"))

    replace(agents: [agent_policy])
    assert_response :success
    replace(agents: [])

    assert_response :success
    assert_empty response.parsed_body.dig("messaging", "agents")
    assert_empty @workspace.reload.messaging_policy.agents
  end

  test "unknown fields do not acquire policy meaning" do
    replace(agents: [agent_policy.merge("default" => "deny")], extra: { "default" => "deny" })

    assert_response :success
    assert_equal [agent_policy], response.parsed_body.dig("messaging", "agents")
    assert_equal [agent_policy], @workspace.reload.messaging_policy.as_json.fetch("agents")
  end

  test "omitting a Private recipient's sender list permits only itself" do
    replace(agents: [{ "agent_public_id" => @recipient.public_id, "mode" => "private" }])

    assert_response :success
    assert_empty response.parsed_body.dig("messaging", "agents").sole.fetch("allowed_sender_public_ids")
    assert_not @workspace.reload.messaging_allowed?(sender: @sender, recipient: @recipient)
    assert @workspace.messaging_allowed?(sender: @recipient, recipient: @recipient)
    assert @workspace.messaging_allowed?(sender: @recipient, recipient: @sender)
  end

  test "Public keeps the allowlist and switching back to Private enforces the same list" do
    other = create_agent_member(steward: users(:owner), agent_identifier: "api-messaging-other")
    public_policy = agent_policy.merge("mode" => "public")
    replace(agents: [public_policy])

    assert_response :success
    assert_equal [public_policy], response.parsed_body.dig("messaging", "agents")
    assert @workspace.reload.messaging_allowed?(sender: other, recipient: @recipient)

    get path, headers: bearer(@member)
    assert_response :success
    private_policy = response.parsed_body.dig("messaging", "agents").sole.merge("mode" => "private")
    replace(agents: [private_policy])

    assert_response :success
    assert_equal [agent_policy], response.parsed_body.dig("messaging", "agents")
    assert @workspace.reload.messaging_allowed?(sender: @sender, recipient: @recipient)
    assert_not @workspace.messaging_allowed?(sender: other, recipient: @recipient)
    assert @workspace.messaging_allowed?(sender: @recipient, recipient: other)
  end

  test "an explicit Public policy with no allowlist still allows contact" do
    replace(agents: [{ "agent_public_id" => @recipient.public_id, "mode" => "public" }])

    assert_response :success
    assert_empty response.parsed_body.dig("messaging", "agents").sole.fetch("allowed_sender_public_ids")
    assert @workspace.reload.messaging_allowed?(sender: @sender, recipient: @recipient)
  end

  test "members may read but only the active Human owner may replace" do
    replace(headers: bearer(@member))

    assert_response :forbidden
    assert_equal "not_workspace_owner", response.parsed_body.dig("error", "code")

    connection = connect_agent_session(steward: users(:owner), agent_identifier: @sender.agent_identifier)
    headers = { "Authorization" => "Bearer #{connection.access_secret}" }
    get path, headers: headers
    assert_response :success

    replace(headers: headers)
    assert_response :forbidden
    assert_equal "not_workspace_owner", response.parsed_body.dig("error", "code")
    assert_empty @workspace.reload.messaging_policy.agents
  end

  test "missing authentication and executor transport do not read the policy" do
    get path
    assert_response :unauthorized

    connection = connect_agent_session(steward: users(:owner), agent_identifier: @sender.agent_identifier)
    get path, headers: { "Authorization" => "Bearer #{connection.executor_access_secret}" }

    assert_response :unauthorized
  end

  test "Workspace data access and tombstones conceal both doors" do
    @workspace = workspaces(:personal)
    get path, headers: bearer(@member)
    assert_response :not_found
    replace(headers: bearer(@owner))
    assert_response :not_found

    @workspace = workspaces(:shared)
    @workspace.update_columns(state: "deleted")
    get path, headers: bearer(@owner)
    assert_response :not_found
    replace
    assert_response :not_found
  end

  test "an archived Workspace remains readable but cannot be edited" do
    @workspace.update_columns(state: "archived", archived_at: Time.current)
    get path, headers: bearer(@member)
    assert_response :success

    replace

    assert_response :conflict
    assert_equal "workspace_not_active", response.parsed_body.dig("error", "code")
  end

  test "stale versions refuse without changing the stored policy" do
    replace
    assert_response :success
    saved = @workspace.reload.messaging_policy

    replace(agents: [], lock_version: @workspace.lock_version - 1)

    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
    assert_equal saved, @workspace.reload.messaging_policy
  end

  test "root agents and lock version are required before replacing the policy" do
    replace
    assert_response :success
    saved = @workspace.reload.messaging_policy
    [
      {},
      { messaging: { lock_version: @workspace.lock_version } },
      { messaging: { agents: [] } },
    ].each do |request|
      put path, headers: bearer(@owner), params: request, as: :json

      assert_response :bad_request
      assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
      assert_equal saved, @workspace.reload.messaging_policy
    end
  end

  test "unknown profiles invalid UUIDs duplicate recipients and invalid modes refuse the replacement" do
    [
      [agent_policy.merge("agent_public_id" => SecureRandom.uuid_v7)],
      [agent_policy.merge("allowed_sender_public_ids" => ["@fixture-agent"])],
      [agent_policy, agent_policy],
      [agent_policy.except("mode")],
      [agent_policy.merge("mode" => "restricted")],
    ].each do |agents|
      replace(agents: agents)

      assert_response :unprocessable_entity
      assert_equal "validation_failed", response.parsed_body.dig("error", "code")
      assert_empty @workspace.reload.messaging_policy.agents
    end
  end

  test "the shared policy byte bound returns 413 without persistence" do
    replace(agents: [agent_policy.merge(
      "allowed_sender_public_ids" => Array.new(2_000) { SecureRandom.uuid_v7 }
    )])

    assert_response :content_too_large
    assert_equal "content_too_large", response.parsed_body.dig("error", "code")
    assert_empty @workspace.reload.messaging_policy.agents
  end

  private

    def path = agent_api_v1_workspace_messaging_path(@workspace)

    def bearer(credential) = { "Authorization" => "Bearer #{credential.secret}" }

    def agent_policy
      { "agent_public_id" => @recipient.public_id, "mode" => "private", "allowed_sender_public_ids" => [@sender.public_id] }
    end

    def replace(agents: [agent_policy], headers: bearer(@owner), lock_version: @workspace.reload.lock_version, extra: {})
      put path, headers: headers, as: :json,
        params: { messaging: { agents: agents, lock_version: lock_version }.merge(extra) }
    end
end
