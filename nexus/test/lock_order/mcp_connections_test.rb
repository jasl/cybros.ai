require "test_helper"
require_relative "../test_helpers/lock_order_test_helper"

class McpConnectionsLockOrderTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  test "connection edits lock the owner before connection authority" do
    connection = mcp_connections(:notes)
    sequences = assert_ladder_order("connection edit") do
      assert connection.revise(attributes: { enabled: false }, expected_lock_version: connection.lock_version).success?
    end
    assert_equal %w[users mcp_connections], sequences.flatten.uniq
  end

  test "OAuth transitions lock the owner before connection authority" do
    connection = users(:member).mcp_connections.create!(name: "OAuth lock order",
      endpoint_url: "https://tools.example.test/mcp", auth_type: "oauth")
    version = connection.lock_version
    assert_connection_authority_lock_order("OAuth begin") do
      assert_predicate connection.begin_oauth_authorization(expected_lock_version: version,
        redirect_uri: "https://nexus.example.test/oauth/callback"), :success?
    end

    data = McpConnection::OAuthData.new(connection.oauth_data.as_json)
    state = "lock-order-state"
    envelope = { "code_verifier" => "lock-order-verifier" }
    data.pending_authorization = McpConnection::OAuthData::PendingAuthorization.new(
      state: state, envelope: envelope, expires_at: 10.minutes.from_now,
      owner_authority_generation: connection.owner.authority_generation)
    assert_connection_authority_lock_order("OAuth pending publication") do
      assert_predicate connection.complete_oauth_operation(operation_id: data.operation.id, data: data), :success?
    end
    assert_equal "pending", connection.reload.authorization_status

    assert_connection_authority_lock_order("OAuth callback claim") do
      assert_predicate connection.claim_oauth_callback(state: state), :success?
    end
    operation_id = connection.oauth_data.operation.id
    assert_connection_authority_lock_order("OAuth callback consumption") do
      assert_equal envelope, connection.consume_oauth_pending(operation_id: operation_id, state: state)
    end
    assert_nil connection.reload.oauth_data.pending_authorization

    data = McpConnection::OAuthData.new(connection.oauth_data.as_json)
    data.tokens = { "access_token" => "lock-order-access", "refresh_token" => "lock-order-refresh",
      "token_type" => "Bearer" }
    data.expires_at = 1.hour.from_now
    assert_connection_authority_lock_order("OAuth credential installation") do
      assert_predicate connection.complete_oauth_operation(operation_id: operation_id, data: data), :success?
    end
    assert_equal "authorized", connection.reload.authorization_status

    travel_to(2.hours.from_now) do
      assert_connection_authority_lock_order("OAuth refresh claim") do
        assert_equal :refresh_required, connection.prepare_oauth_credential.outcome
      end
      data = McpConnection::OAuthData.new(connection.oauth_data.as_json)
      data.tokens = { "access_token" => "rotated-access", "refresh_token" => "rotated-refresh",
        "token_type" => "Bearer" }
      data.expires_at = 1.hour.from_now
      assert_connection_authority_lock_order("OAuth refresh installation") do
        assert_predicate connection.complete_oauth_operation(operation_id: data.operation.id, data: data), :success?
      end
      assert_equal "rotated-access", connection.reload.current_bearer_token
      assert_equal version, connection.lock_version
    end

    assert_connection_authority_lock_order("OAuth disable") do
      assert_predicate connection.revise(attributes: { enabled: false },
        expected_lock_version: connection.lock_version), :success?
    end
    assert_not connection.reload.enabled?
    assert_connection_authority_lock_order("OAuth disconnect") do
      assert_predicate connection.set_credential(bearer_token: nil,
        expected_lock_version: connection.lock_version), :success?
    end
    assert_nil connection.reload.oauth_data
  end

  test "MCP execution takes principal and connection authority before the Run and Task" do
    connection = mcp_connections(:notes)
    agent = users(:agent)
    assert_equal :changed, agent.change_steward(to: connection.owner)
    run = seed({ "tool" => {
      "key" => "lookup", "name" => "search", "input" => { "query" => "notes" },
      "route" => { "kind" => "mcp", "connection_public_id" => connection.public_id },
    } }, workspace: workspaces(:shared), creating_user: agent, default_runner_executor_public_id: nil)
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: users(:member)))
    Runs::ScheduleReady.call(run_id: run.id)
    task = run.tasks.sole
    assert_equal "running", task.status
    client = Object.new
    client.define_singleton_method(:call_tool) { |**| { "content" => [{ "type" => "text", "text" => "Found notes" }] } }
    sequences = Mcp::Client.stub(:open, ->(**, &block) { block.call(client) }) do
      assert_ladder_order("MCP execution") do
        Runs::Mcp::Execute.call(node_id: task.id, execution_generation: task.execution_generation)
      end
    end
    assert_equal "completed", task.reload.status
    assert_includes sequences.flatten.uniq, "users"
    assert_includes sequences.flatten.uniq, "mcp_connections"
    assert_includes sequences.flatten.uniq, "runs"
    assert_includes sequences.flatten.uniq, "tasks"
  end

  private

    def assert_connection_authority_lock_order(flow, &block)
      sequences = assert_ladder_order(flow, &block)
      assert_equal %w[users mcp_connections], sequences.flatten.uniq
    end
end
