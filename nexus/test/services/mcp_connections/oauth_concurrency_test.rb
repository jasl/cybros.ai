require "test_helper"
require_relative "../../test_helpers/mcp_oauth_test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class McpConnections::OAuthConcurrencyTest < ActiveSupport::TestCase
  include McpOAuthTestHelper
  include RowLockTestHelper

  self.use_transactional_tests = false

  teardown do
    @connection&.destroy!
  end

  test "concurrent callers share one refresh and wait without a database lease" do
    started = Queue.new
    finish = Queue.new
    response = ->(form) {
      if form.fetch("grant_type") == "refresh_token"
        started << true
        finish.pop
        { json: { access_token: "fresh-access", refresh_token: "fresh-refresh", token_type: "Bearer", expires_in: 3600 } }
      else
        { json: { access_token: "synthetic-access", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 3600 } }
      end
    }
    first = second = nil
    with_oauth_server(token_response: response) do |server|
      @connection = create_oauth_connection(server)
      authorize_oauth(@connection, server)
      expire_oauth(@connection)
      first = start_database_call { credential }
      Timeout.timeout(5) { started.pop }
      second_waiting = Queue.new
      waiter = McpConnections::OAuth::Credential.new(connection: McpConnection.find(@connection.id), timeout_seconds: 3)
      signaled = false
      wait = ->(_seconds) {
        refute ApplicationRecord.connection_pool.active_connection?, "refresh waiter retained a database lease"
        unless signaled
          second_waiting << true
          finish << true
          signaled = true
        end
        Kernel.sleep(0.01)
      }
      waiter.stub(:sleep, wait) do
        second = start_database_call { waiter.call }
        Timeout.timeout(5) { second_waiting.pop }
        results = [finish_database_call(first), finish_database_call(second)]
        assert results.all?(&:success?)
        assert_equal ["fresh-access", "fresh-access"], results.map(&:bearer_token)
      end
      assert_equal "fresh-refresh", @connection.reload.oauth_data.tokens.fetch("refresh_token")
      assert_equal 2, token_requests(server).size
    end
  ensure
    finish << true if finish
    stop_database_call(first) if first
    stop_database_call(second) if second
  end

  test "an ordinary edit preserves an in-flight token rotation while its stale catalog publication loses" do
    started = Queue.new
    finish = Queue.new
    response = ->(form) {
      if form.fetch("grant_type") == "refresh_token"
        started << true
        finish.pop
        { json: { access_token: "fresh-access", refresh_token: "fresh-refresh", token_type: "Bearer", expires_in: 3600 } }
      else
        { json: { access_token: "synthetic-access", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 3600 } }
      end
    }
    call = nil
    with_oauth_server(token_response: response) do |server|
      @connection = create_oauth_connection(server, catalog: [{ "name" => "old", "input_schema" => { "type" => "object" } }])
      authorize_oauth(@connection, server)
      expire_oauth(@connection)
      version = @connection.lock_version
      client = Object.new
      client.define_singleton_method(:list_tools) { [{ "name" => "new", "input_schema" => { "type" => "object" } }] }
      open = ->(bearer_token:, **, &block) {
        assert_equal "fresh-access", bearer_token
        refute ApplicationRecord.connection_pool.active_connection?, "catalog IO retained a database lease"
        block.call(client)
      }
      Mcp::Client.stub(:open, open) do
        call = start_database_call do
          McpConnections::RefreshCatalog.call(connection: McpConnection.find(@connection.id), expected_lock_version: version)
        end
        Timeout.timeout(5) { started.pop }
        assert_predicate @connection.revise(attributes: { name: "Renamed account" }, expected_lock_version: version), :success?
        finish << true
        assert_equal :stale_object, finish_database_call(call).outcome
      end
      assert_equal "Renamed account", @connection.reload.name
      assert_equal "fresh-access", @connection.current_bearer_token
      assert_equal "fresh-refresh", @connection.oauth_data.tokens.fetch("refresh_token")
      assert_equal ["old"], @connection.tools_catalog.map { |tool| tool.fetch("name") }
      assert_equal 2, token_requests(server).size
    end
  ensure
    finish << true if finish
    stop_database_call(call) if call
  end

  private

    def credential
      McpConnections::OAuth::Credential.call(connection: McpConnection.find(@connection.id), timeout_seconds: 3)
    end
end
