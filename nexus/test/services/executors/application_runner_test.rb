require "test_helper"

class Executors::ApplicationRunnerTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:owner)
    @workspace = workspaces(:shared)
    connection = connect_agent_session(steward: @human, agent_identifier: "local-capability")
    @executor = connection.executor_access_token.executor
    @agent = @executor.agent
  end

  test "one application address executes its runner role and retains write evidence after withdrawal" do
    announcement = {
      "agent" => { "tools" => [{ "name" => "write", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }] },
      "runner" => { "tools" => [{ "name" => "write", "effect_profile" => RunAuthoringTestHelper::WRITE_PROFILE }],
        "environment" => { "root" => "/work" } },
    }
    assert_predicate @executor.announce(services: announcement), :accepted?
    assert_equal %w[agent runner], @executor.reload.service_roles
    run = seed(tool("local-write", "write"), creating_user: @agent,
      default_runner_executor_public_id: @executor.public_id)
    assert_predicate Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @agent)), :accepted?
    clear_enqueued_jobs
    Runs::ScheduleReady.call(run_id: run.id)
    clear_enqueued_jobs
    row = run.tasks.find_by!(node_key: "local-write")
    assert_equal "runner", row.addressed_role
    assert_equal @executor.id, row.addressed_executor_id
    claim = Executors::Claim.call(Executors::Claim::Command.new(run: run, task_key: row.node_key, executor: @executor))
    assert_predicate claim, :accepted?, claim.outcome.to_s
    assert_equal @executor.public_id, claim.value.first_runner_write.fetch("runner_executor_public_id")
    assert_predicate @executor.announce(services: announcement.slice("agent")), :accepted?
    result = Executors::Commit.call(Executors::Commit::Command.new(
      run: run, task_key: row.node_key, executor: @executor, claim_token: claim.value.claim_token,
      content: "written", result_type: nil, outcome: "completed", is_error: false,
      title: nil, metadata: { "checkpoint" => "before-write" }))
    assert_predicate result, :applied?, result.outcome.to_s
    assert_equal "before-write", row.reload.first_runner_write.fetch("checkpoint")
    assert_equal "completed", row.status
  end

  test "another application cannot select the address even under the same Human" do
    assert_predicate @executor.announce(services: { "agent" => { "tools" => [] },
      "runner" => { "tools" => [] } }), :accepted?
    other = create_agent_member(steward: @human)
    refute_predicate Executors::InitialRunner.for(requested: @executor.public_id, principal: @agent), :refused?
    assert_predicate Executors::InitialRunner.for(requested: @executor.public_id, principal: other), :refused?
  end

  test "withdrawal before claim refuses the runner role even when the application serves the same name" do
    service = { "tools" => [{ "name" => "write", "effect_profile" => RunAuthoringTestHelper::WRITE_PROFILE }] }
    assert_predicate @executor.announce(services: { "agent" => service, "runner" => service }), :accepted?
    run = seed(tool("local-write", "write"), creating_user: @agent,
      default_runner_executor_public_id: @executor.public_id)
    assert_predicate Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @agent)), :accepted?
    clear_enqueued_jobs
    Runs::ScheduleReady.call(run_id: run.id)
    clear_enqueued_jobs
    row = run.tasks.find_by!(node_key: "local-write")
    assert_equal "runner", row.addressed_role
    assert_predicate @executor.announce(services: { "agent" => service }), :accepted?

    claim = Executors::Claim.call(Executors::Claim::Command.new(run: run, task_key: row.node_key, executor: @executor))

    assert_equal :tool_not_served, claim.outcome
    assert_nil row.reload.claimed_at
    assert_nil row.first_runner_write
  end
end
