require "test_helper"
require_relative "support/contract_fixtures"

class McpConnectionsTest < Minitest::Test
  PACK = CybrosAgentTest::ContractFixtures.pack("mcp_connections.json").freeze
  CONNECTION = PACK.fetch("member_fixture").fetch("mcp_connection").freeze
  OWNED = PACK.fetch("owner_fixture").fetch("mcp_connection").freeze
  ID = CONNECTION.fetch("public_id").freeze
  TOOL = CONNECTION.fetch("tools").fetch(0).freeze

  def test_agent_reads_its_current_stewards_saved_catalog
    directory = { "mcp_connections" => [CONNECTION], "pagination" => { "next_after" => "cursor" } }
    connection = client([[200, {}, directory], [200, {}, { "mcp_connection" => CONNECTION }]]).mcp_connections
    page = connection.list(limit: 1)
    assert_equal "cursor", page.next_after
    assert_equal ID, page.items.fetch(0).public_id
    assert_equal [TOOL], connection.fetch(ID).tools
    assert_equal "/agent_api/v1/mcp_connections", @transport.requests.first.fetch(:path)
    refute_respond_to connection, :rotate_credential
  end

  def test_owner_create_and_patch_keep_write_only_secrets_and_explicit_disable
    connections = platform([[201, {}, { "mcp_connection" => OWNED }], [200, {}, { "mcp_connection" => OWNED }]]).mcp_connections
    result = connections.create(name: "Work", endpoint_url: OWNED.fetch("endpoint_url"), auth_type: "bearer", bearer_token: "fixture-token")
    assert_equal true, result.credential_configured
    refute_respond_to result, :bearer_token
    assert_equal "fixture-token", @transport.requests.first.fetch(:body).dig("mcp_connection", "bearer_token")
    connections.update(ID, lock_version: 3, enabled: false)
    assert_equal({ "mcp_connection" => { "lock_version" => 3, "enabled" => false } }, @transport.requests.last.fetch(:body))
  end

  def test_agent_directory_and_point_read_keep_the_exact_named_principal
    target = "01900000-0000-7000-8000-000000000092"
    directory = { "mcp_connections" => [CONNECTION], "pagination" => { "next_after" => nil } }
    connections = client([[200, {}, directory], [200, {}, { "mcp_connection" => CONNECTION }]]).mcp_connections
    connections.list(agent_public_id: target, limit: 1)
    connections.fetch(ID, agent_public_id: target)
    assert_equal({ "agent_public_id" => target, "limit" => 1 }, @transport.requests.first.fetch(:params))
    assert_equal({ "agent_public_id" => target }, @transport.requests.last.fetch(:params))
  end

  def test_owner_commands_use_the_same_connection_and_optimistic_version
    connections = platform(Array.new(3) { [200, {}, { "mcp_connection" => OWNED }] }).mcp_connections
    connections.refresh_catalog(ID, lock_version: 3)
    connections.rotate_credential(ID, lock_version: 3, bearer_token: "fixture-new-token")
    connections.clear_credential(ID, lock_version: 3)
    assert_equal %i[post put delete], @transport.requests.map { |request| request.fetch(:method) }
    assert_equal %w[catalog_refresh credential credential], @transport.requests.map { |request| request.fetch(:path).split("/").last }
    assert_equal({ "command" => { "lock_version" => 3 } }, @transport.requests.last.fetch(:body))
  end

  def test_owner_creates_oauth_connection_and_starts_browser_authorization
    oauth = PACK.fetch("oauth_owner_fixture")
    authorization = PACK.fetch("authorization_fixture")
    connections = platform([[201, {}, oauth], [200, {}, authorization]]).mcp_connections
    result = connections.create(name: "Work", endpoint_url: OWNED.fetch("endpoint_url"), auth_type: "oauth")
    assert_equal "oauth", result.auth_type
    assert_equal "authorized", result.authorization_status
    assert_equal oauth.fetch("mcp_connection").fetch("authorization_expires_at"), result.authorization_expires_at
    assert_equal({ "mcp_connection" => { "name" => "Work", "endpoint_url" => OWNED.fetch("endpoint_url"), "auth_type" => "oauth" } },
      @transport.requests.first.fetch(:body))

    started = connections.start_authorization(ID, lock_version: 3)
    assert_equal authorization.fetch("authorization"), started.to_h.transform_keys(&:to_s)
    assert_equal :post, @transport.requests.last.fetch(:method)
    assert_equal "/api/v1/mcp_connections/#{ID}/authorization", @transport.requests.last.fetch(:path)
    assert_equal({ "command" => { "lock_version" => 3 } }, @transport.requests.last.fetch(:body))
    refute_respond_to started, :access_token
    refute_respond_to started, :refresh_token
  end

  def test_owner_reads_future_authorization_status_and_clears_oauth_credentials
    future = PACK.fetch("unknown_authorization_status_fixture")
    cleared = PACK.fetch("oauth_owner_fixture").fetch("mcp_connection").merge(
      "authorization_status" => "not_authorized", "authorization_expires_at" => nil,
      "credential_configured" => false, "available" => false, "lock_version" => 4)
    connections = platform([[200, {}, future], [200, {}, { "mcp_connection" => cleared }]]).mcp_connections
    assert_equal "future_status", connections.fetch(ID).authorization_status
    result = connections.clear_credential(ID, lock_version: 3)
    assert_equal "not_authorized", result.authorization_status
    assert_nil result.authorization_expires_at
    refute result.credential_configured
    assert_equal :delete, @transport.requests.last.fetch(:method)
    assert_equal({ "command" => { "lock_version" => 3 } }, @transport.requests.last.fetch(:body))
  end

  def test_authorization_version_conflict_is_returned_without_retry
    connections = platform([[409, {}, { "error" => { "code" => "stale_object" } }]]).mcp_connections
    error = assert_raises(CybrosAgent::Api::Conflict) { connections.start_authorization(ID, lock_version: 2) }
    assert_equal "stale_object", error.code
    assert_equal 1, @transport.requests.length
  end

  private

    def client(script)
      @transport = CybrosAgentTest::FakeTransport.new(script)
      CybrosAgent::Client.new(base_url: "http://example.test", credential: "fixture-member", transport: @transport)
    end

    def platform(script)
      @transport = CybrosAgentTest::FakeTransport.new(script)
      CybrosAgent::PlatformClient.new(base_url: "http://example.test", credential: "fixture-human", transport: @transport)
    end
end
