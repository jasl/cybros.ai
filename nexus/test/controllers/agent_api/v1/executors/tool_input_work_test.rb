require "test_helper"
require "test_helpers/agent_loop_api_test_helper"

class AgentAPI::V1::Executors::ToolInputWorkTest < ActionDispatch::IntegrationTest
  include AgentLoopAPITestHelper

  test "approval dispatch claim and commit do not revalidate an unchanged file write input" do
    input = write_input
    agent_loop = create_write_loop(input)
    bytes = Nexus::CanonicalJson.bytesize(input)
    work = {}

    work[:park] = input_validation_work do
      post "#{loops_path}/#{agent_loop.public_id}/start", headers: auth
      assert_response :success
      perform_enqueued_jobs(only: AgentLoops::ScheduleJob)
      assert_equal "needs_approval", agent_loop.agent_loop_nodes.sole.status
    end

    work[:approve] = input_validation_work do
      post "#{loops_path}/#{agent_loop.public_id}/tasks/write/approve", headers: auth
      assert_response :success
      assert_equal "dispatched", response.parsed_body.dig("task", "status")
      assert_equal "human", response.parsed_body.dig("task", "approval", "origin")
    end

    token = nil
    work[:claim] = input_validation_work do
      post agent_api_v1_executor_inbox_claim_path(agent_loop_public_id: agent_loop.public_id, task_key: "write"),
        headers: runner_bearer
      assert_response :success
      task = response.parsed_body.fetch("task")
      assert_equal "write", task.fetch("tool_name")
      assert_equal input, task.fetch("tool_input"), "claim still transmits the complete executable input"
      assert_equal true, task.fetch("claimed")
      token = response.parsed_body.dig("claim", "claim_token")
      assert token.present?
    end

    work[:commit] = input_validation_work do
      post agent_api_v1_executor_inbox_commit_path(agent_loop_public_id: agent_loop.public_id, task_key: "write"),
        headers: runner_bearer, as: :json, params: { claim_token: token, content: "File written." }
      assert_response :success
      assert_equal "completed", response.parsed_body.dig("task", "status")
    end

    task = agent_loop.agent_loop_nodes.sole
    assert_equal input, task.tool_input
    assert_equal "File written.", task.output_preview
    calls = work.values.sum { |phase| phase.fetch(:calls) }
    assert_equal 0, calls,
      "unchanged #{bytes}-byte write input revalidated #{calls} times / #{bytes * calls} bytes: #{work.inspect}"
  end

  test "new tool tasks still reject unstorable input" do
    task = create_write_loop(write_input).agent_loop_nodes.sole.dup
    task.node_key = "another-write"
    task.tool_input["content"] = "unstorable\u0000"

    assert_predicate task, :new_record?
    assert_not task.valid?
    assert task.errors.of_kind?(:tool_input, :unsupported_text)
  end

  test "in-place changes to readonly tool input retain the storage refusal" do
    input = write_input
    task = create_write_loop(input).agent_loop_nodes.sole
    task.tool_input["content"] = "unstorable\u0000"

    assert_not task.valid?
    assert task.errors.of_kind?(:tool_input, :unsupported_text)
    assert_equal input, task.reload.tool_input
  end

  private

    # The runner's write contract is path + content. Use a complete source file
    # as a normal file replacement, without expanding it to the payload ceiling.
    def write_input
      { "path" => "lib/input_materialization.rb",
        "content" => Rails.root.join("app/services/conversations/inputs/apply_next.rb").read }
    end

    def create_write_loop(input)
      post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
        agent_loop: {
          approval_mode: "ask",
          approval_rules: [{ tool: "write", verdict: "ask", origin: "author" }],
          runner_executor_public_id: suite_runner.public_id,
          steps: [{ tool: { key: "write", name: "write", input: input } }],
        },
      }
      assert_response :created
      AgentLoop.find_by!(public_id: response.parsed_body.dig("agent_loop", "public_id"))
    end

    def runner_bearer
      { "Authorization" => "Bearer #{suite_runner_connection.executor_access_secret}" }
    end

    # Observe only the model's input validator, calling its real implementation.
    # HTTP response serialization and the protocol's other encoders remain outside
    # this measurement; transmitting the input at claim is required behavior.
    def input_validation_work
      validator = AgentLoopNodes::ToolTask.validators_on(:tool_input).sole
      validate = validator.method(:validate_each)
      work = { calls: 0, allocated_objects: 0, elapsed_ms: 0.0 }
      observed = lambda do |record, attribute, value|
        before = GC.stat(:total_allocated_objects)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = validate.call(record, attribute, value)
        work[:elapsed_ms] += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
        work[:allocated_objects] += GC.stat(:total_allocated_objects) - before
        work[:calls] += 1
        result
      end
      validator.stub(:validate_each, observed) { yield }
      work[:elapsed_ms] = work.fetch(:elapsed_ms).round(3)
      work
    end
end
