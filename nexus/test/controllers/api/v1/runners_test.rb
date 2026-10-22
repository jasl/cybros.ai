require "test_helper"

class API::V1::RunnersTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    credential = create_access_token_fixture(user: @human, name: "Runner management", plane: :platform)
    @headers = { "Authorization" => "Bearer #{credential.secret}" }
  end

  test "management reads private credential-less and revoked machines independently of eligibility" do
    private_runner = machine("private")
    no_credential = machine("without-credential")
    no_credential.revoke_credentials
    revoked = machine("revoked")
    revoked.revoke
    provider = machine("provider", kind: :tool_provider)
    outsider = connect_runner(manager: users(:owner), registration_identifier: "outsider").executor_access_token.executor

    get api_v1_runners_path, headers: @headers
    assert_response :success
    rows = response.parsed_body.fetch("runners").index_by { |row| row.fetch("public_id") }
    assert_equal [private_runner, no_credential, revoked, provider].map(&:public_id).sort, rows.keys.sort
    assert_not_includes rows, outsider.public_id
    assert_equal "user_private", rows.fetch(private_runner.public_id).fetch("assignment_scope")
    assert_equal "ready", rows.fetch(private_runner.public_id).fetch("credential_readiness")
    assert_equal true, rows.fetch(private_runner.public_id).fetch("eligible_for_current_user")
    assert_equal "no_credential", rows.fetch(no_credential.public_id).fetch("credential_readiness")
    assert_equal false, rows.fetch(no_credential.public_id).fetch("eligible_for_current_user")
    assert_equal "revoked", rows.fetch(revoked.public_id).fetch("status")
    assert_equal "tool_provider", rows.fetch(provider.public_id).fetch("kind")
    assert_not rows.fetch(provider.public_id).key?("served_tools"), "announcements load only on detail"
    assert response.parsed_body.fetch("measured_at")

    [private_runner, no_credential, revoked].each do |runner|
      get api_v1_runner_path(runner), headers: @headers
      assert_response :success
      assert_equal runner.public_id, response.parsed_body.dig("runner", "public_id")
    end
  end

  test "detail projects saved announcements and connection facts without writes or jobs" do
    runner = machine("announced")
    tools = [{ "name" => "read", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
      "description" => "Read a file", "input_schema" => { "type" => "object" } }]
    documents = [{ "name" => "project", "description" => "Project instructions" }]
    environment = { "root" => "/srv/project" }
    assert_predicate runner.announce(services: { runner.executor_kind => { "tools" => tools, "documents" => documents, "environment" => environment } }), :accepted?
    runner.update!(last_seen_at: 2.minutes.ago)
    snapshot = runner.attributes
    assert_no_enqueued_jobs do
      assert_no_queries_match(/FOR UPDATE|UPDATE "executors"/) do
        get api_v1_runner_path(runner), headers: @headers
      end
    end
    assert_response :success
    row = response.parsed_body.fetch("runner")
    assert_equal tools, row.fetch("services").fetch("runner").fetch("tools")
    assert_equal documents, row.fetch("services").fetch("runner").fetch("documents")
    assert_equal environment, row.fetch("services").fetch("runner").fetch("environment")
    assert_equal @human.public_id, row.fetch("manager_public_id")
    assert_equal "offline", row.fetch("presence")
    assert_equal true, row.fetch("eligible_for_current_user")
    assert_equal runner.created_at.iso8601, row.fetch("registered_at")
    assert_equal snapshot, runner.reload.attributes
    %w[id manager_id assignment_agent_id credential_epoch registration_identifier].each { |key| assert_not row.key?(key) }
  end

  test "list has bounded opaque pagination stable ordering filters and an empty result" do
    first = machine("first")
    second = machine("second", kind: :tool_provider)
    revoked = machine("revoked")
    revoked.revoke
    get api_v1_runners_path, headers: @headers, params: { limit: 1 }
    assert_response :success
    assert_equal [first.public_id], response.parsed_body.fetch("runners").pluck("public_id")
    cursor = response.parsed_body.dig("pagination", "next_after")
    assert cursor
    assert_not_equal first.public_id, cursor
    get api_v1_runners_path, headers: @headers, params: { limit: 1, after: cursor }
    assert_equal [second.public_id], response.parsed_body.fetch("runners").pluck("public_id")
    get api_v1_runners_path, headers: @headers, params: { order: "desc" }
    assert_equal [revoked, second, first].map(&:public_id), response.parsed_body.fetch("runners").pluck("public_id")
    get api_v1_runners_path, headers: @headers, params: { kind: "tool_provider", status: "active" }
    assert_equal [second.public_id], response.parsed_body.fetch("runners").pluck("public_id")
    get api_v1_runners_path, headers: @headers, params: { kind: "tool_provider", status: "revoked" }
    assert_empty response.parsed_body.fetch("runners")
    [{ limit: 101 }, { after: "invalid" }, { kind: "agent" }, { status: "unknown" }].each do |params|
      get api_v1_runners_path, headers: @headers, params: params
      assert_response :bad_request
      assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    end
  end

  test "collection batches assignment manager and credential reads" do
    3.times do |index|
      connect_runner(manager: @human, registration_identifier: "runner-#{index}")
    end
    ApplicationRecord.uncached do
      assert_queries_match(/access_tokens\.credential_epoch/, count: 1) do
        assert_queries_match(/SELECT "users"\.\* FROM "users"/, count: 1) do
          get api_v1_runners_path, headers: @headers
        end
      end
    end
    assert_response :success
    assert_equal 3, response.parsed_body.fetch("runners").size
  end

  test "another manager and non-manager administrator cannot read a machine and wrong planes do not fall back to cookies" do
    runner = machine("managed")
    admin = create_access_token_fixture(user: users(:owner), name: "Other manager", plane: :platform)
    get api_v1_runner_path(runner), headers: { "Authorization" => "Bearer #{admin.secret}" }
    assert_response :not_found
    get api_v1_runner_path(SecureRandom.uuid_v7), headers: @headers
    assert_response :not_found

    sign_in_as @human
    get api_v1_runner_path(runner)
    assert_response :success
    member = create_access_token_fixture(user: @human, name: "Member")
    transport = connect_runner(manager: @human, registration_identifier: "transport").executor_access_secret
    [member.secret, transport, "invalid"].each do |secret|
      get api_v1_runner_path(runner), headers: { "Authorization" => "Bearer #{secret}" }
      assert_response :unauthorized
    end
    sign_out
    get api_v1_runners_path
    assert_response :unauthorized
  end

  private

    def machine(identifier, kind: :runner)
      connect_runner(manager: @human, registration_identifier: identifier, executor_kind: kind).executor_access_token.executor
    end
end
