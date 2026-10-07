require "test_helper"
require_relative "../../../../test_helpers/rate_limit_test_helper"

class AgentAPI::V1::Executors::ClaimStatusTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include InvocationHarness
  include RunLaneTestHelper
  include RateLimitTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "the exact claim reads active without writes and becomes inactive after force stop" do
    agent_run, token = claimed_work
    node = task(agent_run)
    before = node.attributes
    statements = []
    subscriber = ->(*, payload) { statements << payload.fetch(:sql) }

    # Claim already authenticated this credential, so contact sampling is warm.
    assert_no_enqueued_jobs do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        read_claim(agent_run, token)
        assert_active true
      end
    end
    assert_equal before, node.reload.attributes
    assert_empty statements.grep(/\b(?:INSERT|UPDATE|DELETE|FOR UPDATE|FOR SHARE)\b/i)
    assert_not_includes response.body, token

    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    assert_equal "canceled", agent_run.reload.status
    read_claim(agent_run, token)
    assert_active false
    assert_nil node.reload.output_body
  end

  test "pause and graceful cancellation keep the existing claim active" do
    agent_run, token = claimed_work
    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    read_claim(agent_run, token)
    assert_active true
    assert_equal "paused", agent_run.reload.status

    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: false
    )), :accepted?
    read_claim(agent_run, token)
    assert_active true
    assert_equal "canceling", agent_run.reload.status
  end

  test "deadline projection and retry distinguish the old execution from a new claim of the same key" do
    agent_run, token = claimed_work(timeout_ms: 1_000)
    travel 2.seconds
    # This GET observes persisted state; it must not settle or re-arm expiry.
    read_claim(agent_run, token)
    assert_active true
    assert_nil task(agent_run).output_body

    DatabaseClock.stub(:now, Time.current) { AgentRuns::Parks::TimeoutSweep.call }
    assert_equal "timed_out", task(agent_run).status
    read_claim(agent_run, token)
    assert_active false

    assert_predicate AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "held", acting_user: @human
    )), :accepted?
    read_claim(agent_run, token)
    assert_refused "not_claimant"
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    next_token = claim(agent_run)
    assert_not_equal token, next_token
    read_claim(agent_run, token)
    assert_refused "not_claimant"
    read_claim(agent_run, next_token)
    assert_active true
  end

  test "a background claim remains active while its foreground turn needs attention" do
    agent = users(:agent)
    declare_tools!(agent)
    agent.update!(runner_executor_public_ids: [suite_runner.public_id])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
      answering_user: agent, default_runner_executor: suite_runner)
    _turn, agent_run = materialize_loop_reply!(conversation, agent: agent)
    grow!(agent_run, detached(tool("held", "probe")),
      tool("blocked", "probe", "on_failure" => "halt"))
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("the initial answer"))
    token = claim(agent_run)
    foreground_token = claim(agent_run, key: "blocked")
    post agent_api_v1_executor_inbox_commit_path(run_public_id: agent_run.public_id, task_key: "blocked"),
      headers: headers(secret), as: :json,
      params: { claim_token: foreground_token, content: "cannot run", outcome: "failed" }
    assert_response :success
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    assert_equal "needs_attention", agent_run.reload.status
    # The detached claim was admitted before the foreground failure. The
    # inbox omits the held loop, but its existing execution still belongs here.
    assert_equal "dispatched", task(agent_run).status
    read_claim(agent_run, token)
    assert_active true
  end

  test "reading an accepted result is inactive and leaves its content intact" do
    agent_run, token = claimed_work
    post agent_api_v1_executor_inbox_commit_path(run_public_id: agent_run.public_id, task_key: "held"),
      headers: headers(secret), as: :json,
      params: { claim_token: token, content: "the accepted answer", outcome: "completed" }
    assert_response :success
    assert_equal "completed", task(agent_run).status

    read_claim(agent_run, token)
    assert_active false
    assert_equal "the accepted answer", task(agent_run).output_body.effective_text
  end

  test "a tools provider retains its claimed read through announcement withdrawal and manager shutdown" do
    manager = users(:member)
    assert_equal :role_changed, manager.change_role(to: :admin)
    @human = users(:owner)
    connection = connect_runner(manager: manager, registration_identifier: "claim-status-provider",
      assignment_scope: :account_wide, executor_kind: :tool_provider)
    executor = connection.executor_access_token.task_executor
    assert_predicate executor.announce(tools: [{ "name" => "remote_read",
      "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }]), :accepted?
    agent_run = start_loop(seed(tool("held", "remote_read"), default_runner_executor_public_id: nil))
    token = claim(agent_run, secret: connection.executor_access_secret)
    assert_nil task(agent_run).addressed_executor_id
    assert_predicate executor.announce(tools: []), :accepted?
    assert_equal :removed, manager.remove
    TaskExecutor.converge
    assert_predicate executor.reload, :shutdown_pending?

    read_claim(agent_run, token, secret: connection.executor_access_secret)
    assert_active true
    assert_equal executor.id, task(agent_run).claimed_by_executor_id
  end

  test "changing the default preserves the target and claim without authorizing the newly selected Runner" do
    agent_run, token = claimed_work
    before = task(agent_run).attributes
    replacement = connect_runner(manager: users(:owner), registration_identifier: "replacement",
      assignment_scope: :account_wide)
    runner = replacement.executor_access_token.task_executor
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS), :accepted?
    assert_predicate Executors::DefaultRunner.call(Executors::DefaultRunner::Command.new(
      host: agent_run, executor_public_id: runner.public_id, acting_user: @human
    )), :accepted?
    assert_equal before, task(agent_run).reload.attributes
    assert_equal runner.id, agent_run.reload.default_runner_executor_id

    read_claim(agent_run, token)
    assert_active true
    read_claim(agent_run, token, secret: replacement.executor_access_secret)
    assert_refused "not_claimant"
  end

  test "proof is required in the header and neither errors nor success reveal a token" do
    agent_run, token = claimed_work
    read_claim(agent_run, "different-proof")
    assert_refused "not_claimant"
    assert_not_includes response.body, token
    assert_not_includes response.body, "different-proof"

    [nil, " "].each do |missing|
      get claim_path(agent_run), params: { claim_token: token }, headers: headers(secret, missing)
      assert_response :bad_request
      assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
      assert_includes response.parsed_body.dig("error", "message"), "Claim-Token"
      assert_not_includes response.body, token
    end

    member = create_access_token_fixture(user: @human, name: "Member")
    read_claim(agent_run, token, secret: member.secret)
    assert_response :unauthorized
  end

  test "missing loops and tasks and tombstones are absent even with the old proof" do
    agent_run, token = claimed_work
    get claim_path(agent_run, key: "missing"), headers: headers(secret, token)
    assert_response :not_found
    get agent_api_v1_executor_inbox_claim_path(run_public_id: SecureRandom.uuid_v7, task_key: "held"),
      headers: headers(secret, token)
    assert_response :not_found

    assert_predicate AgentRuns::Stop.stop_now(agent_run), :accepted?
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    assert_predicate AgentRuns::Tombstone.call(agent_run: agent_run.reload), :accepted?
    read_claim(agent_run, token)
    assert_response :not_found
  end

  test "claim reads have a separate six hundred request budget from claim writes" do
    agent_run, token = claimed_work
    Rails.cache.clear
    travel_to Time.current do
      prime_caller_rate_limit(count: AgentAPI::V1::Executors::ClaimsController::CLAIM_READ_RATE_LIMIT - 1) do
        read_claim(agent_run, token)
        assert_response :success
      end
      read_claim(agent_run, token)
      assert_response :success
      read_claim(agent_run, token)
      assert_response :too_many_requests
      assert_equal "60", response.headers["Retry-After"]

      prime_caller_rate_limit(count: AgentAPI::V1::Executors::ClaimsController.caller_rate_limit - 1) do
        post claim_path(agent_run), headers: headers(secret)
        assert_refused "already_claimed"
      end
      post claim_path(agent_run), headers: headers(secret)
      assert_refused "already_claimed"
      post claim_path(agent_run), headers: headers(secret)
      assert_response :too_many_requests
      assert_equal "60", response.headers["Retry-After"]
    end
  end

  private

    def claimed_work(timeout_ms: 60_000)
      agent_run = start_loop(seed(tool("held", "read_file", "timeout_ms" => timeout_ms)))
      [agent_run, claim(agent_run)]
    end

    def start_loop(agent_run)
      assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @human
      )), :accepted?
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      agent_run
    end

    def task(agent_run) = agent_run.agent_run_tasks.find_by!(node_key: "held")

    def secret = suite_runner_connection.executor_access_secret

    def headers(secret, token = nil)
      { "Authorization" => "Bearer #{secret}", "Claim-Token" => token }.compact
    end

    def claim_path(agent_run, key: "held")
      agent_api_v1_executor_inbox_claim_path(run_public_id: agent_run.public_id, task_key: key)
    end

    def claim(agent_run, secret: self.secret, key: "held")
      post claim_path(agent_run, key: key), headers: headers(secret)
      assert_response :success
      response.parsed_body.fetch("claim").fetch("claim_token")
    end

    def read_claim(agent_run, token, secret: self.secret)
      get claim_path(agent_run), headers: headers(secret, token)
    end

    def assert_active(value)
      assert_response :success
      assert_equal({ "claim" => { "active" => value } }, response.parsed_body)
      assert_equal "no-store", response.headers["Cache-Control"]
    end

    def assert_refused(code)
      assert_response :conflict
      assert_equal code, response.parsed_body.dig("error", "code")
    end
end
