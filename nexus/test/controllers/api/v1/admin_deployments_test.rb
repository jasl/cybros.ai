require "test_helper"
require_relative "../../../test_helpers/deployment_test_helper"

class API::V1::AdminDeploymentsTest < ActionDispatch::IntegrationTest
  include DeploymentTestHelper

  PATH = "/api/v1/admin/deployment"

  setup do
    @owner = users(:owner)
    @token = create_access_token_fixture(user: @owner, name: "Deployment operator", plane: :platform)
    @client = fake_deployment_client
  end

  test "status reads only the local Nexus deployment and its configured image source" do
    Nexus::Deployment::Client.stub(:new, @client) do
      assert_no_enqueued_jobs { get PATH, headers: auth }
    end

    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_equal [{ operation: :status }], @client.calls
    state = response.parsed_body.fetch("deployment")
    assert state.fetch("supported")
    assert_equal "registry.example/nexus", state.fetch("sources").first.fetch("reference")
    assert_equal "2610080750", state.dig("candidate", "release")
    assert_equal deployment_preflight, state.fetch("preflight")
    assert_nil state.fetch("active_operation")
  end

  test "release checks are explicit commands and upgrade acceptance records the current Human" do
    Nexus::Deployment::Client.stub(:new, @client) do
      post "#{PATH}/release_check", params: { release_check: { tag: "2610080750", shell: "ignored" } },
        as: :json, headers: auth
      assert_response :success
      assert_equal({ operation: :check, tag: "2610080750", backup: true }, @client.calls.last)

      post "#{PATH}/upgrades", params: { candidate: deployment_release, actor_public_id: users(:member).public_id,
        shell: "ignored" }, as: :json, headers: auth.merge("Idempotency-Key" => IDEMPOTENCY_KEY)
    end

    assert_response :accepted
    assert_equal @owner.public_id, @client.calls.last.fetch(:actor_public_id)
    assert_equal IDEMPOTENCY_KEY, @client.calls.last.fetch(:idempotency_key)
    assert_equal Nexus::Deployment::Release.from_h(deployment_release), @client.calls.last.fetch(:candidate)
    assert_equal OPERATION_ID, response.parsed_body.dig("upgrade", "id")
    assert_equal true, response.parsed_body.dig("upgrade", "backup")
    assert_equal "#{PATH}/upgrades/#{OPERATION_ID}", URI(response.location).path
  end

  test "an explicit false backup choice reaches checks upgrades and receipt reads" do
    Nexus::Deployment::Client.stub(:new, @client) do
      post "#{PATH}/release_check", params: { release_check: { backup: false } }, as: :json, headers: auth
      assert_response :success
      assert_equal false, @client.calls.last.fetch(:backup)
      assert_equal false, response.parsed_body.dig("deployment", "preflight", "backup")

      post "#{PATH}/upgrades", params: { candidate: deployment_release, backup: false },
        as: :json, headers: auth.merge("Idempotency-Key" => IDEMPOTENCY_KEY)
      assert_response :accepted
      assert_equal false, @client.calls.last.fetch(:backup)
      assert_equal false, response.parsed_body.dig("upgrade", "backup")
      assert_nil response.parsed_body.dig("upgrade", "database_backup")

      get "#{PATH}/upgrades/#{OPERATION_ID}", headers: auth
      assert_response :success
      assert_equal false, response.parsed_body.dig("upgrade", "backup")
    end
  end

  test "receipt and bounded log reads preserve the updater cursor without parsing it" do
    @client.back_up(deployment_backup)
    Nexus::Deployment::Client.stub(:new, @client) do
      get "#{PATH}/upgrades/#{OPERATION_ID}", headers: auth
      assert_response :success
      assert_equal OPERATION_ID, response.parsed_body.dig("upgrade", "id")
      assert_equal "backing_up", response.parsed_body.dig("upgrade", "phase")
      assert_equal({ "created_at" => "2026-10-08T09:30:02Z", "size_bytes" => 1_048_576, "available" => true },
        response.parsed_body.dig("upgrade", "database_backup"))

      get "#{PATH}/upgrades/#{OPERATION_ID}/log", params: { cursor: "opaque-cursor", limit: 999_999 }, headers: auth
    end

    assert_response :success
    assert_equal({ operation: :log, operation_id: OPERATION_ID, cursor: "opaque-cursor" }, @client.calls.last)
    assert_equal "tail", response.parsed_body.dig("log", "next_cursor")
    assert_equal "Preparing images\n", response.parsed_body.dig("log", "entries", 0, "text")
    assert_equal true, response.parsed_body.dig("log", "operation", "database_backup", "available")
  end

  test "blocked checks remain readable and a refused acceptance preserves the preflight error" do
    @client.state = @client.state.with(preflight: Nexus::Deployment::Preflight.from_h(deployment_preflight(ready: false)))
    Nexus::Deployment::Client.stub(:new, @client) do
      post "#{PATH}/release_check", as: :json, headers: auth
      assert_response :success
      assert_equal deployment_preflight(ready: false), response.parsed_body.dig("deployment", "preflight")
      assert_equal "2610080750", response.parsed_body.dig("deployment", "candidate", "release")
      get PATH, headers: auth
      assert_response :success
      refute response.parsed_body.dig("deployment", "preflight", "ready")

      @client.failure = deployment_error(code: :preflight_failed, status: 409)
      post "#{PATH}/upgrades", params: { candidate: deployment_release }, as: :json,
        headers: auth.merge("Idempotency-Key" => IDEMPOTENCY_KEY)
    end
    assert_response :conflict
    assert_equal "preflight_failed", response.parsed_body.dig("error", "code")
  end

  test "cookie reads retain the Platform boundary and cookie writes cannot reach the updater" do
    sign_in_as @owner
    Nexus::Deployment::Client.stub(:new, @client) do
      get PATH
      assert_response :success
      @client.calls.clear
      post "#{PATH}/release_check", as: :json
      assert_response :unauthorized
      post "#{PATH}/upgrades", params: { candidate: deployment_release }, as: :json
      assert_response :unauthorized
    end
    assert_empty @client.calls
  end

  test "anonymous non-admin and member or executor credentials cannot read or command deployment" do
    ordinary = create_access_token_fixture(user: users(:member), name: "Ordinary", plane: :platform)
    member = create_access_token_fixture(user: @owner, name: "Member plane")
    executor = create_bound_credential(executor: task_executors(:address), name: "Transport")
    agent = connect_agent_session(steward: @owner, agent_identifier: "deployment-denied")
    attempts = [[{}, :unauthorized], [bearer(ordinary.secret), :forbidden],
      [bearer(member.secret), :unauthorized], [bearer(executor.secret), :unauthorized],
      [bearer(agent.access_secret), :unauthorized]]

    Nexus::Deployment::Client.stub(:new, @client) do
      attempts.each do |headers, status|
        [PATH, "#{PATH}/upgrades/#{OPERATION_ID}", "#{PATH}/upgrades/#{OPERATION_ID}/log",
          "#{PATH}/upgrades/#{OPERATION_ID}/stream"].each do |path|
          get path, headers: headers
          assert_response status
        end
        post "#{PATH}/release_check", as: :json, headers: headers
        assert_response status
        post "#{PATH}/upgrades", params: { candidate: deployment_release }, as: :json, headers: headers
        assert_response status
      end
    end
    assert_empty @client.calls
  end

  test "demotion revocation and removal are applied to later requests" do
    admin = users(:member)
    assert_equal :role_changed, admin.change_role(to: :admin)
    token = create_access_token_fixture(user: admin, name: "Temporary operator", plane: :platform)
    headers = bearer(token.secret)
    Nexus::Deployment::Client.stub(:new, @client) do
      get PATH, headers: headers
      assert_response :success
      assert_equal :role_changed, admin.change_role(to: :member)
      get PATH, headers: headers
      assert_response :forbidden
      assert_equal :role_changed, admin.change_role(to: :admin)
      token.token.revoke
      get PATH, headers: headers
      assert_response :unauthorized
      token = create_access_token_fixture(user: admin, name: "Removed operator", plane: :platform)
      assert_equal :removed, admin.remove
      get PATH, headers: bearer(token.secret)
      assert_response :unauthorized
    end
    assert_equal [{ operation: :status }], @client.calls
  end

  test "unsupported and unavailable are distinct and errors retain an existing operation id" do
    Nexus::Deployment::Client.stub(:new, Nexus::Deployment::Client.new(socket_path: nil)) do
      get PATH, headers: auth
      assert_response :success
      refute response.parsed_body.dig("deployment", "supported")
    end

    @client.failure = deployment_error(code: :upgrade_in_progress, status: 409, operation_id: OPERATION_ID)
    Nexus::Deployment::Client.stub(:new, @client) do
      post "#{PATH}/upgrades", params: { candidate: deployment_release }, as: :json,
        headers: auth.merge("Idempotency-Key" => IDEMPOTENCY_KEY)
    end
    assert_response :conflict
    assert_equal "upgrade_in_progress", response.parsed_body.dig("error", "code")
    assert_equal OPERATION_ID, response.parsed_body.dig("error", "operation_id")

    @client.failure = deployment_error
    Nexus::Deployment::Client.stub(:new, @client) { get PATH, headers: auth }
    assert_response :service_unavailable
    assert_equal "updater_unavailable", response.parsed_body.dig("error", "code")
  end

  test "a completed progress stream carries versioned events and resumes the supplied cursor" do
    @client.back_up(deployment_backup)
    @client.complete
    Nexus::Deployment::Client.stub(:new, @client) do
      get "#{PATH}/upgrades/#{OPERATION_ID}/stream", params: { cursor: "query-cursor" },
        headers: auth.merge("Last-Event-ID" => "header-cursor")
    end

    assert_response :success
    assert_equal "text/event-stream", response.media_type
    assert_includes response.body, "event: deployment.progress.v1"
    assert_includes response.body, "id: tail"
    assert_includes response.body, '"status":"succeeded"'
    assert_includes response.body, '"database_backup":{"created_at":"2026-10-08T09:30:02Z","size_bytes":1048576,"available":true}'
    assert_equal({ operation: :log, operation_id: OPERATION_ID, cursor: "query-cursor" }, @client.calls.sole)
  end

  private

    def auth = bearer(@token.secret)
    def bearer(secret) = { "Authorization" => "Bearer #{secret}" }
end
