require "test_helper"
require "test_helpers/agent_loop_api_test_helper"

class AgentAPI::V1::AgentLoopWaitsTest < ActionDispatch::IntegrationTest
  include AgentLoopAPITestHelper

  test "wait authoring returns a durable target without a resolution capability" do
    agent_loop = created_loop([
      { ask: { key: "source", prompt: "external work", detached: true } },
      { wait: { key: "join", task: "source", timeout_ms: 5000 } },
    ])
    receipt = response.parsed_body.fetch("receipt")
    assert_equal ["source"], receipt.fetch("resolution_tokens").keys

    get "#{loops_path}/#{agent_loop.public_id}/tasks/join", headers: auth
    assert_response :success
    task = response.parsed_body.fetch("task")
    assert_equal "await_task", task.fetch("kind")
    assert_equal({ "agent_loop" => agent_loop.public_id, "task" => "source", "timeout_ms" => 5000 }, task.fetch("wait"))
    assert_nil task["resolution_token"]
  end

  test "invalid target and another standalone execution are refused atomically" do
    original = created_loop([{ ask: { key: "source", prompt: "work" } }])
    waiter = created_loop([{ ask: { key: "gate", prompt: "hold" } }])
    assert_no_difference -> { waiter.agent_loop_nodes.count } do
      post "#{loops_path}/#{waiter.public_id}/tasks", headers: auth("foreign-wait"), as: :json,
        params: { steps: [{ wait: { task: "source", agent_loop: original.public_id } }] }
    end
    assert_response :unprocessable_entity
    assert_equal "wait_target_not_found", response.parsed_body.dig("error", "code")

    post "#{loops_path}/#{waiter.public_id}/tasks", headers: auth("malformed-wait"), as: :json,
      params: { steps: [{ wait: { task: "../source" } }] }
    assert_response :unprocessable_entity
    assert_equal "invalid_task_key", response.parsed_body.dig("error", "steps", 0, "code")
  end
end
