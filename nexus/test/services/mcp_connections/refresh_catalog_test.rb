require "test_helper"

class McpConnections::RefreshCatalogTest < ActiveSupport::TestCase
  setup do
    @connection = mcp_connections(:notes)
  end

  test "complete discovery exposes the current catalog to the owner's Agents" do
    tool = { "name" => "delete", "description" => "Delete a note", "input_schema" => { "type" => "object" } }
    catalog = @connection.tools_catalog + [tool]
    discover(catalog) do
      assert McpConnections::RefreshCatalog.call(connection: @connection, expected_lock_version: @connection.lock_version).success?
    end
    assert_equal catalog, @connection.reload.tools_catalog
    assert_not_nil @connection.catalog_refreshed_at
    agent = users(:agent)
    assert_equal :changed, agent.change_steward(to: @connection.owner)
    assert @connection.tool_available?(agent: agent, name: "delete")
  end

  test "a failed page leaves the complete saved catalog unchanged" do
    before = @connection.tools_catalog
    client = Object.new
    client.define_singleton_method(:list_tools) { raise Mcp::Error.new(:invalid_response, request_sent: false) }
    Mcp::Client.stub(:open, ->(**, &block) { block.call(client) }) do
      result = McpConnections::RefreshCatalog.call(connection: @connection, expected_lock_version: @connection.lock_version)
      assert_equal :discovery_failed, result.outcome
    end
    assert_equal before, @connection.reload.tools_catalog
    assert_nil @connection.catalog_refreshed_at
  end

  test "an edit committed during network discovery wins over the returned catalog" do
    prior = @connection.tools_catalog
    version = @connection.lock_version
    client = Object.new
    connection = @connection
    client.define_singleton_method(:list_tools) do
      current = McpConnection.find(connection.id)
      current.revise(attributes: { name: "Latest name" }, expected_lock_version: current.lock_version)
      []
    end
    Mcp::Client.stub(:open, ->(**, &block) { block.call(client) }) do
      result = McpConnections::RefreshCatalog.call(connection: @connection, expected_lock_version: version)
      assert_equal :stale_object, result.outcome
    end
    assert_equal prior, @connection.reload.tools_catalog
    assert_equal "Latest name", @connection.name
  end

  test "a missing credential refuses discovery before transport" do
    connection = users(:member).mcp_connections.create!(name: "Token missing", auth_type: "bearer",
      endpoint_url: "https://notes.example.test/mcp")
    Mcp::Client.stub(:open, ->(**) { flunk "unexpected network request" }) do
      assert_equal :missing_credential,
        McpConnections::RefreshCatalog.call(connection: connection, expected_lock_version: connection.lock_version).outcome
    end
  end

  test "credential preparation and catalog discovery share one timeout budget" do
    times = [0, 0, 7]
    discovery = McpConnections::RefreshCatalog.new(connection: @connection, expected_lock_version: @connection.lock_version)
    client = Object.new
    client.define_singleton_method(:list_tools) { [] }
    credential = ->(connection:, timeout_seconds:) {
      assert_equal 20, timeout_seconds
      McpConnections::OAuth::Result.new(outcome: :saved, connection: connection)
    }
    open = ->(timeout_seconds:, **, &block) {
      assert_equal 13, timeout_seconds
      block.call(client)
    }
    discovery.stub(:monotonic_time, -> { times.shift }) do
      McpConnections::OAuth::Credential.stub(:call, credential) do
        Mcp::Client.stub(:open, open) { assert_predicate discovery.call, :success? }
      end
    end
  end

  test "an exhausted authorization budget never starts discovery" do
    times = [0, 0, 21]
    discovery = McpConnections::RefreshCatalog.new(connection: @connection, expected_lock_version: @connection.lock_version)
    discovery.stub(:monotonic_time, -> { times.shift }) do
      Mcp::Client.stub(:open, ->(**) { flunk "unexpected discovery after timeout" }) do
        assert_equal :discovery_failed, discovery.call.outcome
      end
    end
  end

  private

    def discover(catalog, &)
      client = Object.new
      client.define_singleton_method(:list_tools) { catalog }
      Mcp::Client.stub(:open, ->(**, &block) { block.call(client) }, &)
    end
end
