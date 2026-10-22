require "test_helper"

class AgentAPI::V1::Executors::RealtimeTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @member = AccessTokens::IssueAPIKey.call(user: @human, name: "Realtime")
    @run = seed(tool("held", "read_file", "timeout_ms" => 60_000))
    assert_predicate Runs::Start.call(Runs::Start::Command.new(run: @run, acting_user: @human)), :accepted?
    Runs::ScheduleReady.call(run_id: @run.id)
    post executor_path.sub(/realtime\z/, "claim"), headers: executor_headers
    assert_response :success
    @claim = response.parsed_body.dig("claim", "claim_token")
    @connection_id = "01900000-0000-7000-8000-000000000099"
  end

  test "only the exact claim can offer and the executing member can answer" do
    get executor_path, headers: executor_headers
    assert_status "waiting"
    put executor_path, headers: executor_headers.merge("Claim-Token" => "wrong"),
      params: { connection_id: @connection_id, sdp: sdp }, as: :json
    assert_response :conflict
    assert_equal "not_claimant", response.parsed_body.dig("error", "code")
    offer
    assert_status "waiting"
    get member_path, headers: member_headers
    assert_status "waiting"
    assert_equal sdp, response.parsed_body.dig("realtime", "offer_sdp")
    answer
    assert_status "active"
    get executor_path, headers: executor_headers
    assert_status "active"
    assert_equal sdp("BB"), response.parsed_body.dig("realtime", "answer_sdp")
    assert_equal Nexus::Contract.pack.fetch("executor_inbox.json").fetch("realtime_fixture"), response.parsed_body
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_not_includes response.body, @claim
    raw = Task.where(id: node.id).pick(Arel.sql("realtime_signal"))
    assert_not_includes raw, "fingerprint"
  end

  test "pause and member revocation deny interaction while exact claim remains active" do
    offer
    answer
    assert_predicate Runs::Pause.call(Runs::Pause::Command.graceful(run: @run, acting_user: @human)), :accepted?
    get executor_path, headers: executor_headers
    assert_status "paused"
    assert_equal 0, response.parsed_body.dig("realtime", "max_age_ms")
    assert_claim_active
    assert_predicate Runs::Resume.call(Runs::Resume::Command.new(run: @run.reload, acting_user: @human)), :accepted?
    get executor_path, headers: executor_headers
    assert_status "active"
    @member.token.revoke
    get executor_path, headers: executor_headers
    assert_status "closed"
    assert_nil response.parsed_body.dig("realtime", "answer_sdp")
    assert_claim_active
  end

  test "force and graceful Stop close interaction through existing execution facts" do
    offer
    answer
    assert_predicate Runs::Stop.call(Runs::Stop::Command.new(run: @run, acting_user: @human, force: false)), :accepted?
    get executor_path, headers: executor_headers
    assert_status "closed"
    assert_claim_active
    assert_predicate Runs::Stop.call(Runs::Stop::Command.forced(run: @run.reload, acting_user: @human)), :accepted?
    Runs::ScheduleReady.call(run_id: @run.id)
    get executor_path, headers: executor_headers
    assert_status "closed"
    assert_equal "canceled", node.status
  end

  test "deadline is enforced before sweep and reads do not mutate task or acquire row locks" do
    offer
    answer
    get executor_path, headers: executor_headers
    before = node.attributes
    statements = []
    subscriber = ->(*, payload) { statements << payload.fetch(:sql) }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      get executor_path, headers: executor_headers
      assert_status "active"
    end
    assert_equal before, node.attributes
    assert_empty statements.grep(/\b(?:INSERT|UPDATE|DELETE|FOR UPDATE|FOR SHARE|pg_advisory)\b/i)
    travel 61.seconds
    get executor_path, headers: executor_headers
    assert_status "closed"
    assert_equal "deadline_passed", response.parsed_body.dig("realtime", "reason")
    assert_claim_active
  end

  test "active reads keep authority lookups bounded on both credential planes" do
    offer
    answer
    [[executor_path, executor_headers], [member_path, member_headers]].each do |path, headers|
      get path, headers: headers
      statements = []
      subscriber = ->(*, payload) do
        statements << payload.fetch(:sql) unless payload[:cached] || payload[:name] == "SCHEMA"
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        get path, headers: headers
      end
      assert_status "active"
      assert_operator statements.length, :<=, 12, statements.join("\n")
    end
  end

  test "handshake retries are immutable and old connection replies cannot replace the current peer" do
    offer
    answer
    answer
    assert_status "active"
    put member_path, headers: member_headers, params: { connection_id: @connection_id, sdp: sdp("CC") }, as: :json
    assert_response :conflict
    old = @previous_connection_id = @connection_id
    @connection_id = SecureRandom.uuid_v7
    offer
    assert_status "waiting"
    put member_path, headers: member_headers, params: { connection_id: old, sdp: sdp("BB") }, as: :json
    assert_response :conflict
    put executor_path, headers: executor_headers, params: { connection_id: old, sdp: sdp }, as: :json
    assert_response :conflict
  end

  test "a new member credential cannot renew the revoked old handshake" do
    offer
    answer
    @member.token.revoke
    @member = AccessTokens::IssueAPIKey.call(user: @human, name: "Realtime")
    @previous_connection_id = @connection_id
    answer
    assert_response :conflict
    @connection_id = SecureRandom.uuid_v7
    offer
    answer
    assert_status "active"
  end

  test "member plane and executor plane cannot substitute for each other or another agent" do
    offer
    get executor_path, headers: member_headers
    assert_response :unauthorized
    get member_path, headers: executor_headers
    assert_response :unauthorized
    @member = AccessTokens::IssueAPIKey.call(user: create_agent_member, name: "Other")
    get member_path, headers: member_headers
    assert_response :forbidden
  end

  test "signals reject oversized SDP and ambiguous DTLS identities" do
    [sdp + "x" * 65_536, "v=0\r\n", sdp + "a=fingerprint:sha-256 #{(["BB"] * 32).join(":")}\r\n"].each do |invalid|
      put executor_path, headers: executor_headers, params: { connection_id: @connection_id, sdp: invalid }, as: :json
      assert_response :bad_request
      assert_nil node.realtime_signal
    end
  end

  test "a named Agent uses its application credential but retains its own standing" do
    declared = Users::DeclareNamedAgent.call(caller: @human, name: "realtime", scope: "instance",
      description: "Interactive work", configuration: { tool_definitions: [], approval_mode: "bypass", approval_rules: nil,
        prompt_mechanism: "default", prompt_template: nil, compaction_policy: nil })
    assert_predicate declared, :accepted?
    named = declared.user
    @run = seed(tool("held", "read_file"), creating_user: named)
    assert_predicate Runs::Start.call(Runs::Start::Command.new(run: @run, acting_user: @human)), :accepted?
    Runs::ScheduleReady.call(run_id: @run.id)
    post executor_path.sub(/realtime\z/, "claim"), headers: executor_headers
    assert_response :success
    @claim = response.parsed_body.dig("claim", "claim_token")
    offer
    answer
    assert_status "active"
    assert_equal :removed, named.remove
    get executor_path, headers: executor_headers
    assert_status "closed"
    assert_predicate @member.token.reload, :usable?
  end

  test "maintenance denies new interaction without a read-side admission lock" do
    offer
    answer
    Deployments::Maintenance.prepare
    get executor_path, headers: executor_headers
    assert_status "paused"
    assert_claim_active
  end

  test "the original executor credential cannot be substituted by another token on a read" do
    offer
    answer
    original = suite_runner_connection.executor_access_token
    replacement = AccessTokens::IssueAPIKey.call(user: nil, executor: suite_runner, name: "Replacement")
    assert_equal :issued, replacement.outcome
    original.revoke
    get executor_path, headers: { "Authorization" => "Bearer #{replacement.secret}", "Claim-Token" => @claim }
    assert_status "closed"
    assert_equal "executor_credential_revoked", response.parsed_body.dig("realtime", "reason")
  end

  test "an application runner claim keeps realtime after role withdrawal and retains its original credential" do
    application = Executor.address_for(@human)
    @application_transport = create_bound_credential(executor: application, name: "Application realtime")
    assert_predicate application.announce(services: {
      "agent" => { "tools" => [] },
      "runner" => { "tools" => [{ "name" => "read_file", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }] },
    }), :accepted?
    @run = seed(tool("held", "read_file", "timeout_ms" => 60_000),
      default_runner_executor_public_id: application.public_id)
    assert_predicate Runs::Start.call(Runs::Start::Command.new(run: @run, acting_user: @human)), :accepted?
    Runs::ScheduleReady.call(run_id: @run.id)
    @claim = nil
    post executor_path.sub(/realtime\z/, "claim"), headers: executor_headers
    assert_response :success
    @claim = response.parsed_body.dig("claim", "claim_token")
    assert_equal "runner", node.addressed_role
    assert_equal application.id, node.claimed_by_executor_id
    offer
    answer
    assert_status "active"

    assert_predicate application.announce(services: { "agent" => { "tools" => [] } }), :accepted?
    get executor_path, headers: executor_headers
    assert_status "active"
    assert_claim_active

    replacement = AccessTokens::IssueAPIKey.call(user: @human, executor: application, name: "Replacement")
    assert_equal :issued, replacement.outcome
    @application_transport.token.revoke
    get executor_path, headers: { "Authorization" => "Bearer #{replacement.secret}", "Claim-Token" => @claim }
    assert_status "closed"
    assert_equal "executor_credential_revoked", response.parsed_body.dig("realtime", "reason")
  end

  private

    def node = @run.tasks.find_by!(node_key: "held")
    def executor_path = "/agent_api/v1/executor/inbox/#{@run.public_id}/held/realtime"
    def member_path = "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{@run.public_id}/tasks/held/realtime"
    def executor_headers = { "Authorization" => "Bearer #{@application_transport&.secret || suite_runner_connection.executor_access_secret}", "Claim-Token" => @claim }.compact
    def member_headers = { "Authorization" => "Bearer #{@member.secret}" }
    def sdp(byte = "AA") = "v=0\r\na=fingerprint:sha-256 #{([byte] * 32).join(":")}\r\n"

    def offer
      put executor_path, headers: executor_headers, params: { connection_id: @connection_id, previous_connection_id: @previous_connection_id, sdp: sdp }, as: :json
    end

    def answer
      put member_path, headers: member_headers, params: { connection_id: @connection_id, sdp: sdp("BB") }, as: :json
    end

    def assert_status(status)
      assert_response :success
      assert_equal status, response.parsed_body.dig("realtime", "status")
    end

    def assert_claim_active
      get executor_path.sub(/realtime\z/, "claim"), headers: executor_headers
      assert_response :success
      assert_equal true, response.parsed_body.dig("claim", "active")
    end
end
