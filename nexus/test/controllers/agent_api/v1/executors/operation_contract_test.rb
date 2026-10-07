require "test_helper"
require_relative "../../../../support/nexus_contract"

class AgentAPI::V1::Executors::OperationContractTest < ActionDispatch::IntegrationTest
  setup do
    @fixture = Nexus::Contract.pack.fetch("executor_operations.json")
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!
    @runner = suite_runner
    @runner.announce(tools: RunAuthoringTestHelper::TEST_SERVED_TOOLS + [{
      "name" => "program", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
    }])
    context = @fixture.dig("pages", "initial", "operations", "context")
    @loop = seed(tool("program", "program", "route" => { "kind" => "runner" }, "model_defaults" => context.fetch("model_defaults").merge(
      "tools" => context.fetch("tools").map { |tool| tool.merge("route" => { "kind" => "runner", "runner_executor_public_id" => @runner.public_id, "tool_name" => "read_file" }) }
    )))
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: @loop, acting_user: @human))
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    @parent = @loop.agent_run_tasks.sole
    @token = claim(@parent.node_key)
  end

  test "the shared trace pack follows acceptance observation replay paging and final commit over HTTP" do
    snapshot
    assert_fixture @fixture.dig("pages", "initial")
    accept_read
    post route("observation"), params: { claim_token: @token, after: 1 }, headers: bearer, as: :json
    assert_response :ok
    assert_fixture @fixture.fetch("waiting_observation")
    finish_child(@fixture.dig("outcomes", "false", "commit_request"))
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    assert_equal @token, @parent.reload.claim_token
    2.times do
      post route("observation"), params: { claim_token: @token, after: 1 }, headers: bearer, as: :json
      assert_response :ok
      assert_fixture @fixture.dig("outcomes", "false", "observation")
    end
    snapshot(after: 0, limit: 1)
    assert_fixture @fixture.dig("pages", "page_1")
    snapshot(after: 1, limit: 1)
    assert_fixture @fixture.dig("pages", "page_2")
    snapshot
    assert_fixture @fixture.dig("pages", "complete")

    2.times do
      post route("commit"), params: @fixture.dig("final", "commit_request").merge("claim_token" => @token),
        headers: bearer, as: :json
      assert_response :ok
      assert_final_fixture
    end
    post route("commit"), params: { claim_token: @token, content: "complete", structured_content: nil },
      headers: bearer, as: :json
    assert_response :conflict
    assert_equal "final_result_conflict", response.parsed_body.dig("error", "code")
  end

  test "the paused control refusal accepts nothing and the same operation can be submitted after Resume" do
    operation = @fixture.dig("accepted_operation", "operation")
    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: @loop, acting_user: @human
    )), :accepted?
    assert_no_difference ["AgentRunTaskOperation.count", "AgentRunTask.count"] do
      submit(operation)
      assert_response :conflict
      assert_equal @fixture.fetch("paused_operation"), response.parsed_body
    end
    assert_predicate AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
      agent_run: @loop, acting_user: @human
    )), :accepted?
    submit(operation)
    assert_response :created
    @child_key = response.parsed_body.dig("operation", "receipt", "task_keys").sole
    assert_fixture @fixture.fetch("accepted_operation")
    assert_equal @token, @parent.reload.claim_token
  end

  test "the shared refusal is durable at both the acceptance and observation doors" do
    operation = @fixture.dig("refused_operation", "operation")
    submit(operation)
    assert_response :created
    assert_fixture @fixture.fetch("refused_operation")
    post route("observation"), params: { claim_token: @token, after: 1 }, headers: bearer, as: :json
    assert_response :ok
    assert_fixture @fixture.fetch("refused_observation")
    submit(operation)
    assert_response :ok
    assert_fixture @fixture.fetch("refused_operation")
    assert_equal 1, @loop.agent_run_tasks.count
  end

  %w[false null absent_structured absent_output].each do |name|
    test "the shared #{name} outcome preserves result presence through the HTTP commit and observation" do
      accept_read
      fixture = @fixture.fetch("outcomes").fetch(name)
      finish_child(fixture.fetch("commit_request"))
      post route("observation"), params: { claim_token: @token, after: 1 }, headers: bearer, as: :json
      assert_response :ok
      assert_fixture fixture.fetch("observation")
    end
  end

  private

    def bearer = { "Authorization" => "Bearer #{suite_runner_connection.executor_access_secret}" }
    def route(resource, key: @parent.node_key) = "/agent_api/v1/executor/inbox/#{@loop.public_id}/#{key}/#{resource}"

    def claim(key)
      post route("claim", key: key), headers: bearer, as: :json
      assert_response :ok
      response.parsed_body.fetch("claim").fetch("claim_token")
    end

    def submit(operation)
      post route("operations"), params: { claim_token: @token, operation: operation.slice("key", "request") },
        headers: bearer, as: :json
    end

    def accept_read
      operation = @fixture.dig("accepted_operation", "operation")
      submit(operation)
      assert_response :created
      @child_key = response.parsed_body.dig("operation", "receipt", "task_keys").sole
      assert_fixture @fixture.fetch("accepted_operation")
      submit(operation)
      assert_response :ok
      assert_fixture @fixture.fetch("accepted_operation")
    end

    def finish_child(request)
      AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
      token = claim(@child_key)
      post route("commit", key: @child_key), params: request.merge("claim_token" => token), headers: bearer, as: :json
      assert_response :ok
    end

    def snapshot(**params)
      get route("operations"), params: params, headers: bearer.merge("Claim-Token" => @token)
      assert_response :ok
    end

    def normalized_body
      identities = @fixture.fetch("identities")
      substitutions = { @loop.public_id => identities.fetch("run_public_id"),
        @runner.public_id => identities.fetch("executor_public_id"), @runner.display_name => "Fixture runner" }
      substitutions[@child_key] = identities.fetch("child_task_key") if @child_key
      encoded = substitutions.reduce(response.body) { |body, (actual, fixture)| body.gsub(actual, fixture) }
      JSON.parse(encoded)
    end

    def assert_fixture(expected)
      assert_equal expected, normalized_body
    end

    def assert_final_fixture
      actual = normalized_body
      expected = @fixture.dig("final", "response")
      task = actual.fetch("task")
      %w[created_at started_at completed_at].each do |field|
        assert Time.iso8601(task.fetch(field))
        task[field] = expected.dig("task", field)
      end
      assert Time.iso8601(task.fetch("approval").fetch("decided_at"))
      task.fetch("approval")["decided_at"] = expected.dig("task", "approval", "decided_at")
      assert Time.iso8601(task.fetch("addressed_to").fetch("last_seen_at"))
      task.fetch("addressed_to")["last_seen_at"] = expected.dig("task", "addressed_to", "last_seen_at")
      assert_equal expected, actual
    end
end
