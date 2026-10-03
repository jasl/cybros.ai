require "test_helper"
require "test_helpers/agent_loop_api_test_helper"

class AgentAPI::V1::AgentLoopGraphReadsTest < ActionDispatch::IntegrationTest
  include AgentLoopAPITestHelper

  test "expanded graph reads keep ownership and result selection without loading bodies or taking locks" do
    agent_loop = created_loop([
      { script: { key: "workflow", script: "g.script({script: 'return 42;'});" } },
      { script: { key: "report", script: "return results;", results: ["workflow"] } },
    ])
    post "#{loops_path}/#{agent_loop.public_id}/start", headers: auth
    assert_response :success
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    root = agent_loop.agent_loop_nodes.find_by!(node_key: "workflow")
    assert_equal "running", root.status
    AgentLoops::ScriptJob.perform_now(root.id, root.execution_generation)
    child = agent_loop.agent_loop_nodes.where(expansion_parent_id: root.id).sole

    queries = graph_queries(agent_loop)
    nodes = response.parsed_body.fetch("nodes").index_by { |node| node.fetch("key") }
    assert_equal "workflow", nodes.fetch(child.node_key).fetch("expansion_parent")
    assert_not nodes.fetch("workflow").key?("expansion_parent")
    assert_equal [child.node_key], nodes.fetch("report").fetch("result_from")
    assert_equal [], nodes.fetch("report").fetch("input_from")
    assert_equal [{ "from" => "workflow", "to" => "report", "structural" => true },
                  { "from" => child.node_key, "to" => "report", "structural" => true },
                  { "from" => "workflow", "to" => child.node_key, "structural" => true }],
      response.parsed_body.fetch("edges")
    assert_no_graph_payload_or_lock_queries(queries)
  end

  test "graph query count stays constant as nodes and dependencies grow" do
    small = created_loop([
      { tool: { key: "a", name: "read_file" } },
      { tool: { key: "b", name: "read_file" } },
    ])
    large = created_loop(Array.new(30) { |index| { tool: { key: "t#{index}", name: "read_file" } } })
    # Warm the route, then measure two uncached requests through the same authority path.
    get "#{loops_path}/#{small.public_id}/graph", headers: auth
    one = graph_queries(small)
    many = graph_queries(large)

    assert_equal one.length, many.length, "graph size must not add queries\n#{many.join("\n")}"
    assert_equal 1, many.count { |sql| sql.include?('FROM "agent_loop_nodes"') }
    assert_equal 1, many.count { |sql| sql.include?('FROM "agent_loop_edges"') }
    assert_equal 30, response.parsed_body.fetch("nodes").length
    assert_equal 29, response.parsed_body.fetch("edges").length
    assert_no_graph_payload_or_lock_queries(many)
  end

  private

    def graph_queries(agent_loop)
      ApplicationRecord.connection_pool.clear_query_cache
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) {
        queries << payload[:sql] unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
      }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        get "#{loops_path}/#{agent_loop.public_id}/graph", headers: auth
      end
      assert_response :success
      queries
    end

    def assert_no_graph_payload_or_lock_queries(queries)
      assert_no_match(/content_bodies|content_body_entries|content_fragments|FOR UPDATE|FOR SHARE|FOR KEY SHARE/, queries.join("\n"))
    end
end
