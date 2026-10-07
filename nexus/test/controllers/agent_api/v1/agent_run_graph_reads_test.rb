require "test_helper"
require "test_helpers/agent_run_api_test_helper"

class AgentAPI::V1::AgentRunGraphReadsTest < ActionDispatch::IntegrationTest
  include AgentRunAPITestHelper

  test "expanded graph reads keep ownership and result selection without loading bodies or taking locks" do
    DevModelLane.ensure_enabled!(@account)
    agent_run = created_loop([
      { model: { key: "workflow", prompt: "plan", model: { model: "dev/mock-text" } } },
      { model: { key: "report", prompt: "report", model: { model: "dev/mock-text" }, results: ["workflow"] } },
    ])
    post "#{loops_path}/#{agent_run.public_id}/start", headers: auth
    assert_response :success
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    root = agent_run.agent_run_tasks.find_by!(node_key: "workflow")
    assert_equal "running", root.status
    expanded = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: agent_run, steps: [AgentRuns::Tasks::Step::Model.new(key: "child", model: MOCK_MODEL, prompt: "expanded")],
      tip: AgentRuns::KernelTool.branch_tip(root), origin: "model", expansion_parent: root, replaces: root.node_key
    ))
    assert_predicate expanded, :applied?, expanded.inspect
    child = agent_run.agent_run_tasks.where(expansion_parent_id: root.id).sole

    queries = graph_queries(agent_run)
    nodes = response.parsed_body.fetch("nodes").index_by { |node| node.fetch("key") }
    assert_equal "workflow", nodes.fetch(child.node_key).fetch("expansion_parent")
    assert_not nodes.fetch("workflow").key?("expansion_parent")
    assert_equal [child.node_key], nodes.fetch("report").fetch("result_from")
    assert_equal [child.node_key], nodes.fetch("report").fetch("input_from")
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
    assert_equal 1, many.count { |sql| sql.include?('FROM "agent_run_tasks"') }
    assert_equal 1, many.count { |sql| sql.include?('FROM "agent_run_edges"') }
    assert_equal 30, response.parsed_body.fetch("nodes").length
    assert_equal 29, response.parsed_body.fetch("edges").length
    assert_no_graph_payload_or_lock_queries(many)
  end

  private

    def graph_queries(agent_run)
      ApplicationRecord.connection_pool.clear_query_cache
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) {
        queries << payload[:sql] unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
      }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        get "#{loops_path}/#{agent_run.public_id}/graph", headers: auth
      end
      assert_response :success
      queries
    end

    def assert_no_graph_payload_or_lock_queries(queries)
      assert_no_match(/content_bodies|content_body_entries|content_fragments|FOR UPDATE|FOR SHARE|FOR KEY SHARE/, queries.join("\n"))
    end
end
