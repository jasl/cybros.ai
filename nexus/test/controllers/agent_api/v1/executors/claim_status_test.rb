require "test_helper"
require_relative "../../../../test_helpers/rate_limit_test_helper"

class AgentAPI::V1::Executors::ClaimStatusTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include InvocationHarness
  include LoopLaneTestHelper
  include RateLimitTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "the exact claim reads active without writes and becomes inactive after force stop" do
    agent_loop, token = claimed_work
    node = task(agent_loop)
    before = node.attributes
    statements = []
    subscriber = ->(*, payload) { statements << payload.fetch(:sql) }

    # Claim already authenticated this credential, so contact sampling is warm.
    assert_no_enqueued_jobs do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        read_claim(agent_loop, token)
        assert_active true
      end
    end
    assert_equal before, node.reload.attributes
    assert_empty statements.grep(/\b(?:INSERT|UPDATE|DELETE|FOR UPDATE|FOR SHARE)\b/i)
    assert_not_includes response.body, token

    assert_predicate AgentLoops::Stop.call(AgentLoops::Stop::Command.forced(
      agent_loop: agent_loop, acting_user: @human
    )), :accepted?
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    assert_equal "canceled", agent_loop.reload.status
    read_claim(agent_loop, token)
    assert_active false
    assert_nil node.reload.output_body
  end

  test "pause and graceful cancellation keep the existing claim active" do
    agent_loop, token = claimed_work
    assert_predicate AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(
      agent_loop: agent_loop, acting_user: @human
    )), :accepted?
    read_claim(agent_loop, token)
    assert_active true
    assert_equal "paused", agent_loop.reload.status

    assert_predicate AgentLoops::Stop.call(AgentLoops::Stop::Command.new(
      agent_loop: agent_loop, acting_user: @human, force: false
    )), :accepted?
    read_claim(agent_loop, token)
    assert_active true
    assert_equal "canceling", agent_loop.reload.status
  end

  test "deadline projection and retry distinguish the old execution from a new claim of the same key" do
    agent_loop, token = claimed_work(timeout_ms: 1_000)
    travel 2.seconds
    # This GET observes persisted state; it must not settle or re-arm expiry.
    read_claim(agent_loop, token)
    assert_active true
    assert_nil task(agent_loop).output_body

    DatabaseClock.stub(:now, Time.current) { AgentLoops::Parks::TimeoutSweep.call }
    assert_equal "timed_out", task(agent_loop).status
    read_claim(agent_loop, token)
    assert_active false

    assert_predicate AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: "held", acting_user: @human
    )), :accepted?
    read_claim(agent_loop, token)
    assert_refused "not_claimant"
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    next_token = claim(agent_loop)
    assert_not_equal token, next_token
    read_claim(agent_loop, token)
    assert_refused "not_claimant"
    read_claim(agent_loop, next_token)
    assert_active true
  end

  test "a background claim remains active while its foreground turn needs attention" do
    agent = users(:agent)
    declare_tools!(agent)
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
      answering_user: agent, runner_executor: suite_runner)
    _turn, agent_loop = materialize_loop_reply!(conversation, agent: agent)
    grow!(agent_loop, detached(tool("held", "probe")),
      tool("blocked", "probe", "on_failure" => "halt"))
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("the initial answer"))
    token = claim(agent_loop)
    foreground_token = claim(agent_loop, key: "blocked")
    post agent_api_v1_executor_inbox_commit_path(agent_loop_public_id: agent_loop.public_id, task_key: "blocked"),
      headers: headers(secret), as: :json,
      params: { claim_token: foreground_token, content: "cannot run", outcome: "failed" }
    assert_response :success
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    assert_equal "needs_attention", agent_loop.reload.status
    # The detached claim was admitted before the foreground failure. The
    # inbox omits the held loop, but its existing execution still belongs here.
    assert_equal "dispatched", task(agent_loop).status
    read_claim(agent_loop, token)
    assert_active true
  end

  test "reading an accepted result is inactive and leaves its content intact" do
    agent_loop, token = claimed_work
    post agent_api_v1_executor_inbox_commit_path(agent_loop_public_id: agent_loop.public_id, task_key: "held"),
      headers: headers(secret), as: :json,
      params: { claim_token: token, content: "the accepted answer", outcome: "completed" }
    assert_response :success
    assert_equal "completed", task(agent_loop).status

    read_claim(agent_loop, token)
    assert_active false
    assert_equal "the accepted answer", task(agent_loop).output_body.effective_text
  end

  test "a tools provider retains its claimed read through announcement withdrawal and manager shutdown" do
    manager = users(:member)
    assert_equal :role_changed, manager.change_role(to: :admin)
    @human = users(:owner)
    connection = connect_runner(manager: manager, runner_identifier: "claim-status-provider",
      assignment_scope: :account_wide, executor_kind: :tools_provider)
    executor = connection.executor_access_token.task_executor
    assert_predicate executor.announce(tools: [{ "name" => "remote_read",
      "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }]), :accepted?
    agent_loop = start_loop(seed(tool("held", "remote_read"), runner_executor_public_id: nil))
    token = claim(agent_loop, secret: connection.executor_access_secret)
    assert_nil task(agent_loop).addressed_executor_id
    assert_predicate executor.announce(tools: []), :accepted?
    assert_equal :removed, manager.remove
    TaskExecutor.converge
    assert_predicate executor.reload, :shutdown_pending?

    read_claim(agent_loop, token, secret: connection.executor_access_secret)
    assert_active true
    assert_equal executor.id, task(agent_loop).claimed_by_executor_id
  end

  test "handoff preserves the original claimant rather than authorizing the new bound runner" do
    agent_loop, token = claimed_work
    replacement = connect_runner(manager: users(:owner), runner_identifier: "replacement",
      assignment_scope: :account_wide)
    runner = replacement.executor_access_token.task_executor
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS), :accepted?
    assert_predicate Executors::Handoff.call(Executors::Handoff::Command.new(
      host: agent_loop, executor_public_id: runner.public_id, acting_user: @human
    )), :accepted?

    read_claim(agent_loop, token)
    assert_active true
    read_claim(agent_loop, token, secret: replacement.executor_access_secret)
    assert_refused "not_claimant"
  end

  test "proof is required in the header and neither errors nor success reveal a token" do
    agent_loop, token = claimed_work
    read_claim(agent_loop, "different-proof")
    assert_refused "not_claimant"
    assert_not_includes response.body, token
    assert_not_includes response.body, "different-proof"

    [nil, " "].each do |missing|
      get claim_path(agent_loop), params: { claim_token: token }, headers: headers(secret, missing)
      assert_response :bad_request
      assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
      assert_includes response.parsed_body.dig("error", "message"), "Claim-Token"
      assert_not_includes response.body, token
    end

    member = create_access_token_fixture(user: @human, name: "Member")
    read_claim(agent_loop, token, secret: member.secret)
    assert_response :unauthorized
  end

  test "missing loops and tasks and tombstones are absent even with the old proof" do
    agent_loop, token = claimed_work
    get claim_path(agent_loop, key: "missing"), headers: headers(secret, token)
    assert_response :not_found
    get agent_api_v1_executor_inbox_claim_path(agent_loop_public_id: SecureRandom.uuid_v7, task_key: "held"),
      headers: headers(secret, token)
    assert_response :not_found

    assert_predicate AgentLoops::Stop.stop_now(agent_loop), :accepted?
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    assert_predicate AgentLoops::Tombstone.call(agent_loop: agent_loop.reload), :accepted?
    read_claim(agent_loop, token)
    assert_response :not_found
  end

  test "claim reads have a separate six hundred request budget from claim writes" do
    agent_loop, token = claimed_work
    Rails.cache.clear
    travel_to Time.current do
      prime_caller_rate_limit(count: AgentAPI::V1::Executors::ClaimsController::CLAIM_READ_RATE_LIMIT - 1) do
        read_claim(agent_loop, token)
        assert_response :success
      end
      read_claim(agent_loop, token)
      assert_response :success
      read_claim(agent_loop, token)
      assert_response :too_many_requests
      assert_equal "60", response.headers["Retry-After"]

      prime_caller_rate_limit(count: AgentAPI::V1::Executors::ClaimsController.caller_rate_limit - 1) do
        post claim_path(agent_loop), headers: headers(secret)
        assert_refused "already_claimed"
      end
      post claim_path(agent_loop), headers: headers(secret)
      assert_refused "already_claimed"
      post claim_path(agent_loop), headers: headers(secret)
      assert_response :too_many_requests
      assert_equal "60", response.headers["Retry-After"]
    end
  end

  private

    def claimed_work(timeout_ms: 60_000)
      agent_loop = start_loop(seed(tool("held", "read_file", "timeout_ms" => timeout_ms)))
      [agent_loop, claim(agent_loop)]
    end

    def start_loop(agent_loop)
      assert_predicate AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      )), :accepted?
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      agent_loop
    end

    def task(agent_loop) = agent_loop.agent_loop_nodes.find_by!(node_key: "held")

    def secret = suite_runner_connection.executor_access_secret

    def headers(secret, token = nil)
      { "Authorization" => "Bearer #{secret}", "Claim-Token" => token }.compact
    end

    def claim_path(agent_loop, key: "held")
      agent_api_v1_executor_inbox_claim_path(agent_loop_public_id: agent_loop.public_id, task_key: key)
    end

    def claim(agent_loop, secret: self.secret, key: "held")
      post claim_path(agent_loop, key: key), headers: headers(secret)
      assert_response :success
      response.parsed_body.fetch("claim").fetch("claim_token")
    end

    def read_claim(agent_loop, token, secret: self.secret)
      get claim_path(agent_loop), headers: headers(secret, token)
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
