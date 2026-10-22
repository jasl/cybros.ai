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
    run, token = claimed_work
    node = task(run)
    before = node.attributes
    statements = []
    subscriber = ->(*, payload) { statements << payload.fetch(:sql) }

    # Claim already authenticated this credential, so contact sampling is warm.
    assert_no_enqueued_jobs do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        read_claim(run, token)
        assert_active true
      end
    end
    assert_equal before, node.reload.attributes
    assert_empty statements.grep(/\b(?:INSERT|UPDATE|DELETE|FOR UPDATE|FOR SHARE)\b/i)
    assert_not_includes response.body, token

    assert_predicate Runs::Stop.call(Runs::Stop::Command.forced(
      run: run, acting_user: @human
    )), :accepted?
    Runs::ScheduleReady.call(run_id: run.id)
    assert_equal "canceled", run.reload.status
    read_claim(run, token)
    assert_active false
    assert_nil node.reload.output_body
  end

  test "pause and graceful cancellation keep the existing claim active" do
    run, token = claimed_work
    assert_predicate Runs::Pause.call(Runs::Pause::Command.graceful(
      run: run, acting_user: @human
    )), :accepted?
    read_claim(run, token)
    assert_active true
    assert_equal "paused", run.reload.status

    assert_predicate Runs::Stop.call(Runs::Stop::Command.new(
      run: run, acting_user: @human, force: false
    )), :accepted?
    read_claim(run, token)
    assert_active true
    assert_equal "canceling", run.reload.status
  end

  test "deadline projection and retry distinguish the old execution from a new claim of the same key" do
    run, token = claimed_work(timeout_ms: 1_000)
    travel 2.seconds
    # This GET observes persisted state; it must not settle or re-arm expiry.
    read_claim(run, token)
    assert_active true
    assert_nil task(run).output_body

    DatabaseClock.stub(:now, Time.current) { Runs::Parks::TimeoutSweep.call }
    assert_equal "timed_out", task(run).status
    read_claim(run, token)
    assert_active false

    assert_predicate Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: run, task_key: "held", acting_user: @human
    )), :accepted?
    read_claim(run, token)
    assert_refused "not_claimant"
    Runs::ScheduleReady.call(run_id: run.id)
    next_token = claim(run)
    assert_not_equal token, next_token
    read_claim(run, token)
    assert_refused "not_claimant"
    read_claim(run, next_token)
    assert_active true
  end

  test "a background claim remains active while its foreground turn needs attention" do
    agent = users(:agent)
    declare_tools!(agent)
    agent.update!(runner_executor_public_ids: [suite_runner.public_id])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
      answering_user: agent, default_runner_executor: suite_runner)
    _turn, run = materialize_loop_reply!(conversation, agent: agent)
    grow!(run, detached(tool("held", "probe")),
      tool("blocked", "probe", "on_failure" => "halt"))
    schedule_loop!(run)
    run_loop_round!(run, sse_success("the initial answer"))
    token = claim(run)
    foreground_token = claim(run, key: "blocked")
    post agent_api_v1_executor_inbox_commit_path(run_public_id: run.public_id, task_key: "blocked"),
      headers: headers(secret), as: :json,
      params: { claim_token: foreground_token, content: "cannot run", outcome: "failed" }
    assert_response :success
    Runs::ScheduleReady.call(run_id: run.id)
    assert_equal "needs_attention", run.reload.status
    # The detached claim was admitted before the foreground failure. The
    # inbox omits the held loop, but its existing execution still belongs here.
    assert_equal "dispatched", task(run).status
    read_claim(run, token)
    assert_active true
  end

  test "reading an accepted result is inactive and leaves its content intact" do
    run, token = claimed_work
    post agent_api_v1_executor_inbox_commit_path(run_public_id: run.public_id, task_key: "held"),
      headers: headers(secret), as: :json,
      params: { claim_token: token, content: "the accepted answer", outcome: "completed" }
    assert_response :success
    assert_equal "completed", task(run).status

    read_claim(run, token)
    assert_active false
    assert_equal "the accepted answer", task(run).output_body.effective_text
  end

  test "a tools provider retains its claimed read through announcement withdrawal and manager shutdown" do
    manager = users(:member)
    assert_equal :role_changed, manager.change_role(to: :admin)
    @human = users(:owner)
    connection = connect_runner(manager: manager, registration_identifier: "claim-status-provider",
      assignment_scope: :account_wide, executor_kind: :tool_provider)
    executor = connection.executor_access_token.executor
    assert_predicate executor.announce(services: { executor.executor_kind => { "tools" => [{ "name" => "remote_read",
      "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }] } }), :accepted?
    run = start_loop(seed(tool("held", "remote_read"), default_runner_executor_public_id: nil))
    token = claim(run, secret: connection.executor_access_secret)
    assert_nil task(run).addressed_executor_id
    assert_predicate executor.announce(services: { executor.executor_kind => { "tools" => [] } }), :accepted?
    assert_equal :removed, manager.remove
    Executor.converge
    assert_predicate executor.reload, :shutdown_pending?

    read_claim(run, token, secret: connection.executor_access_secret)
    assert_active true
    assert_equal executor.id, task(run).claimed_by_executor_id
  end

  test "changing the default preserves the target and claim without authorizing the newly selected Runner" do
    run, token = claimed_work
    before = task(run).attributes
    replacement = connect_runner(manager: users(:owner), registration_identifier: "replacement",
      assignment_scope: :account_wide)
    runner = replacement.executor_access_token.executor
    assert_predicate runner.announce(services: { runner.executor_kind => { "tools" => TEST_SERVED_TOOLS } }), :accepted?
    assert_predicate Executors::DefaultRunner.call(Executors::DefaultRunner::Command.new(
      host: run, executor_public_id: runner.public_id, acting_user: @human
    )), :accepted?
    assert_equal before, task(run).reload.attributes
    assert_equal runner.id, run.reload.default_runner_executor_id

    read_claim(run, token)
    assert_active true
    read_claim(run, token, secret: replacement.executor_access_secret)
    assert_refused "not_claimant"
  end

  test "proof is required in the header and neither errors nor success reveal a token" do
    run, token = claimed_work
    read_claim(run, "different-proof")
    assert_refused "not_claimant"
    assert_not_includes response.body, token
    assert_not_includes response.body, "different-proof"

    [nil, " "].each do |missing|
      get claim_path(run), params: { claim_token: token }, headers: headers(secret, missing)
      assert_response :bad_request
      assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
      assert_includes response.parsed_body.dig("error", "message"), "Claim-Token"
      assert_not_includes response.body, token
    end

    member = create_access_token_fixture(user: @human, name: "Member")
    read_claim(run, token, secret: member.secret)
    assert_response :unauthorized
  end

  test "missing loops and tasks and tombstones are absent even with the old proof" do
    run, token = claimed_work
    get claim_path(run, key: "missing"), headers: headers(secret, token)
    assert_response :not_found
    get agent_api_v1_executor_inbox_claim_path(run_public_id: SecureRandom.uuid_v7, task_key: "held"),
      headers: headers(secret, token)
    assert_response :not_found

    assert_predicate Runs::Stop.stop_now(run), :accepted?
    Runs::ScheduleReady.call(run_id: run.id)
    assert_predicate Runs::Tombstone.call(run: run.reload), :accepted?
    read_claim(run, token)
    assert_response :not_found
  end

  test "claim reads have a separate six hundred request budget from claim writes" do
    run, token = claimed_work
    Rails.cache.clear
    travel_to Time.current do
      prime_caller_rate_limit(count: AgentAPI::V1::Executors::ClaimsController::CLAIM_READ_RATE_LIMIT - 1) do
        read_claim(run, token)
        assert_response :success
      end
      read_claim(run, token)
      assert_response :success
      read_claim(run, token)
      assert_response :too_many_requests
      assert_equal "60", response.headers["Retry-After"]

      prime_caller_rate_limit(count: AgentAPI::V1::Executors::ClaimsController.caller_rate_limit - 1) do
        post claim_path(run), headers: headers(secret)
        assert_refused "already_claimed"
      end
      post claim_path(run), headers: headers(secret)
      assert_refused "already_claimed"
      post claim_path(run), headers: headers(secret)
      assert_response :too_many_requests
      assert_equal "60", response.headers["Retry-After"]
    end
  end

  private

    def claimed_work(timeout_ms: 60_000)
      run = start_loop(seed(tool("held", "read_file", "timeout_ms" => timeout_ms)))
      [run, claim(run)]
    end

    def start_loop(run)
      assert_predicate Runs::Start.call(Runs::Start::Command.new(
        run: run, acting_user: @human
      )), :accepted?
      Runs::ScheduleReady.call(run_id: run.id)
      run
    end

    def task(run) = run.tasks.find_by!(node_key: "held")

    def secret = suite_runner_connection.executor_access_secret

    def headers(secret, token = nil)
      { "Authorization" => "Bearer #{secret}", "Claim-Token" => token }.compact
    end

    def claim_path(run, key: "held")
      agent_api_v1_executor_inbox_claim_path(run_public_id: run.public_id, task_key: key)
    end

    def claim(run, secret: self.secret, key: "held")
      post claim_path(run, key: key), headers: headers(secret)
      assert_response :success
      response.parsed_body.fetch("claim").fetch("claim_token")
    end

    def read_claim(run, token, secret: self.secret)
      get claim_path(run), headers: headers(secret, token)
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
