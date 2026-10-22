require_relative "../test_helper"
require_relative "../support/ops_harness"

class OpsTerminalsTest < Minitest::Test
  include RhoTest::OpsHarness

  def test_creation_starts_one_fixed_terminal_with_original_rules_without_waiting_for_completion
    api = NexusDoubles::FakeAgentApi.new(executors: [NexusDoubles.remote_runner("runner-1")])
    daemon = member_ready(boot, api)
    response = request(daemon, :post, "/terminals", token: bearer(daemon),
      body: { runner_executor_public_id: "runner-1", idempotency_key: "retry-one", workspace_public_id: "ws-1" })

    assert_equal "201", response.code, response.body
    assert_equal({ "public_id" => "al-1", "task_key" => "call_tool", "workspace_public_id" => "ws-1" },
      JSON.parse(response.body).fetch("terminal"))
    run = api.run_creates.fetch(0).fetch("run")
    assert_equal [{ "tool" => { "name" => "terminal", "input" => {}, "key" => "call_tool",
      "route" => { "kind" => "runner", "runner_executor_public_id" => "runner-1" },
      "executor_context" => { "rho.environment" => { "root" => "/srv/elsewhere", "directories" => [], "anchor" => nil } } } }], run.fetch("steps")
    assert_equal Rho::RunDeclaration.request_rules(roots: Rho.protected_roots(daemon.home)), run.fetch("approval_rules")
    paths = api.requests.map(&:first)
    assert paths.any? { |path| path.end_with?("/runs/al-1/start") }
    refute paths.any? { |path| path.include?("/tasks/") || path.end_with?("/stop") }
  end

  def test_creation_requires_authentication_runner_and_retry_key_before_authoring
    api = NexusDoubles::FakeAgentApi.new
    daemon = member_ready(boot, api)
    assert_equal "401", request(daemon, :post, "/terminals", body: {}).code
    [{}, { runner_executor_public_id: "runner-1" }, { idempotency_key: "one" }].each do |body|
      assert_equal "400", request(daemon, :post, "/terminals", token: bearer(daemon), body: body).code
    end
    assert_empty api.run_creates
  end

  def test_reopen_list_excludes_runs_containing_other_work
    task = NexusDoubles::RUNNING_TRACE.fetch("tasks").first.merge("key" => "call_tool", "kind" => "tool_task", "tool_name" => "terminal")
    trace = NexusDoubles::RUNNING_TRACE.merge("tasks" => [task])
    api = NexusDoubles::FakeAgentApi.new(trace: trace, run_list: [trace])
    daemon = member_ready(boot, api)
    response = request(daemon, :get, "/terminals?workspace_public_id=ws-1", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    assert_equal ["al-9"], JSON.parse(response.body).fetch("terminals").map { |row| row.fetch("public_id") }
    trace.fetch("tasks") << NexusDoubles::RUNNING_TRACE.fetch("tasks").first
    response = request(daemon, :get, "/terminals?workspace_public_id=ws-1", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    assert_empty JSON.parse(response.body).fetch("terminals")
  end
end
