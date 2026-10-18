require "test_helper"
require_relative "../../../test_helpers/runs_execution_test_helper"
require_relative "../../../test_helpers/row_lock_test_helper"

# Ordinary scheduler recovery can overlap a delayed original job. Both observe
# running/unstarted, but only the locked Task winner may create an external effect.
class Runs::Mcp::DuplicateJobsTest < ActiveJob::TestCase
  include RunsExecutionTestHelper
  include RowLockTestHelper

  self.use_transactional_tests = false

  teardown do
    Runs::Reap.destroy_aggregate(@run.reload) if @run
    @connection&.destroy!
  end

  test "overlapping deliveries create one committed start and release the DB connection before IO" do
    agent = users(:agent)
    @connection = agent.steward.mcp_connections.create!(name: "Concurrent MCP",
      endpoint_url: "https://tools.example.test/mcp", auth_type: "none",
      catalog: [{ "name" => "write", "input_schema" => { "type" => "object" } }])
    @run = seed({ "tool" => { "key" => "send", "name" => "write", "input" => {},
      "route" => { "kind" => "mcp", "connection_public_id" => @connection.public_id } } },
      creating_user: agent, default_runner_executor_public_id: nil)
    start!(@run)
    task = node(@run, "send")
    calls = Queue.new
    client = Object.new
    client.define_singleton_method(:call_tool) do |**arguments|
      calls << arguments
      { "content" => [{ "type" => "text", "text" => "written once" }] }
    end
    open = ->(**, &block) {
      refute ApplicationRecord.connection_pool.active_connection?, "remote IO retained its database lease"
      block.call(client)
    }
    first = second = held = nil
    Mcp::Client.stub(:open, open) do
      held = hold_row_lock(Run, @run.id)
      first = start_database_call { Runs::McpToolJob.perform_now(task.id, task.execution_generation) }
      second = start_database_call { Runs::McpToolJob.perform_now(task.id, task.execution_generation) }
      wait_until_transitively_blocked_by(held.pid, first.pid, second.pid)
      release_row_lock(held)
      finish_database_call(first)
      finish_database_call(second)
    end
    assert_equal 1, calls.size
    assert_equal "completed", task.reload.status
    assert_not_nil task.external_started_at
    assert_nil task.claimed_at
    assert_equal "written once", task.output_body.effective_text
  ensure
    release_row_lock(held) if held&.thread&.alive?
    stop_database_call(first) if first
    stop_database_call(second) if second
  end

  test "a duplicate credential failure cannot settle an already started sender" do
    agent = users(:agent)
    @connection = agent.steward.mcp_connections.create!(name: "Concurrent authorization",
      endpoint_url: "https://tools.example.test/mcp", auth_type: "oauth",
      oauth_data: { tokens: { "access_token" => "synthetic-access", "token_type" => "Bearer" } },
      catalog: [{ "name" => "write", "input_schema" => { "type" => "object" } }])
    @run = seed({ "tool" => { "key" => "send", "name" => "write", "input" => {},
      "route" => { "kind" => "mcp", "connection_public_id" => @connection.public_id } } },
      creating_user: agent, default_runner_executor_public_id: nil)
    start!(@run)
    task = node(@run, "send")
    first_ready = Queue.new
    second_ready = Queue.new
    request_started = Queue.new
    reject_duplicate = Queue.new
    finish_request = Queue.new
    mutex = Mutex.new
    arrivals = 0
    credential = ->(connection:, **) {
      arrival = mutex.synchronize { arrivals += 1 }
      if arrival == 1
        first_ready << true
        second_ready.pop
        McpConnections::OAuth::Result.new(outcome: :saved, connection: connection, bearer_token: "synthetic-access")
      else
        second_ready << true
        reject_duplicate.pop
        McpConnections::OAuth::Result.new(outcome: :reauthorization_required, connection: connection)
      end
    }
    open = ->(**) {
      request_started << true
      finish_request.pop
      raise Mcp::Error.new(:mcp_authentication_failed, request_sent: true)
    }
    first = second = nil
    McpConnections::OAuth::Credential.stub(:call, credential) do
      Mcp::Client.stub(:open, open) do
        first = start_database_call { Runs::McpToolJob.perform_now(task.id, task.execution_generation) }
        Timeout.timeout(5) { first_ready.pop }
        second = start_database_call { Runs::McpToolJob.perform_now(task.id, task.execution_generation) }
        Timeout.timeout(5) { request_started.pop }
        reject_duplicate << true
        finish_database_call(second)
        assert_equal "running", task.reload.status
        assert_not_nil task.external_started_at
        finish_request << true
        finish_database_call(first)
      end
    end
    assert_equal "uncertain", task.reload.status
    assert_equal "tool_uncertain", task.error_key
    assert_equal "reauthorization_required", @connection.reload.authorization_status
  ensure
    stop_database_call(first) if first
    stop_database_call(second) if second
  end
end
