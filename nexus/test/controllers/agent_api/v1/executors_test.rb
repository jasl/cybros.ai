require "test_helper"

# AUTHORIZED DISCOVERY: the executors the acting principal may address — a runner to bind, a
# provider whose pool serves it — with what each announced. Filtered by ELIGIBILITY, never by
# presence: presence and the contact sample are shown and never used to choose; a credential-less
# row is never offered; an ineligible id conceals as absence.
class AgentAPI::V1::ExecutorsTest < ActionDispatch::IntegrationTest
  ENTRY = {
    "name" => "read", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
    "timeout_ms" => 90_000, "description" => "Read a file",
    "input_schema" => { "type" => "object", "properties" => { "path" => { "type" => "string" } } },
  }.freeze
  ENVIRONMENT = { "root" => "/srv/work", "fragments" => [{ "extension" => "x", "text" => "Paths resolve against /srv/work." }] }.freeze

  setup do
    @owner = users(:owner)
    @member = users(:member)
    DevModelLane.ensure_enabled!(accounts(:cybros))
    @owner_token = create_access_token_fixture(user: @owner, name: "Owner").secret
    @member_token = create_access_token_fixture(user: @member, name: "Member").secret
    # An agent's member bearer is OAuth-issued: the owner's agent, connected.
    @agent_token = connect_agent_session(steward: @owner, agent_identifier: "discovering").access_secret
  end

  def auth(secret) = { "Authorization" => "Bearer #{secret}" }

  DOCUMENT = { "name" => "deploy-notes", "description" => "How this project is deployed." }.freeze

  def runner(identifier, manager: @owner, scope: :user_private, kind: :runner, tools: [ENTRY], environment: ENVIRONMENT,
             documents: [DOCUMENT])
    executor = connect_runner(manager: manager, registration_identifier: identifier, display_name: identifier,
      assignment_scope: scope, executor_kind: kind).executor_access_token.executor
    outcome = executor.announce(services: { executor.executor_kind => { "tools" => tools, "environment" => environment, "documents" => documents } })
    raise outcome.outcome.to_s unless outcome.accepted?

    executor
  end

  def listed_ids(token, query = { role: "runner" })
    get "/agent_api/v1/executors", params: query, headers: auth(token)
    assert_response :success
    response.parsed_body.fetch("executors").map { |row| row.fetch("public_id") }
  end

  test "the listing is per principal: the owner's private runner for the owner and the owner's agent, not for another Human" do
    private_runner = runner("owner-private")
    wide = runner("wide", scope: :account_wide)
    runner("revoked").revoke
    runner("no-credential").revoke_credentials

    assert_equal [private_runner.public_id, wide.public_id], listed_ids(@owner_token)
    assert_equal [private_runner.public_id, wide.public_id], listed_ids(@agent_token),
      "the owner's agent is stewarded by the owner"
    assert_equal [wide.public_id], listed_ids(@member_token)
  end

  test "kind narrows to runners or providers, absent lists both machine kinds, anything else is 400" do
    a_runner = runner("r")
    provider = runner("p", kind: :tool_provider)

    assert_equal [a_runner.public_id, provider.public_id], listed_ids(@owner_token, {})
    assert_equal [a_runner.public_id], listed_ids(@owner_token, kind: "runner")
    assert_equal [provider.public_id], listed_ids(@owner_token, kind: "tool_provider")

    assert_empty listed_ids(@owner_token, kind: "agent")
    get "/agent_api/v1/executors", params: { kind: "unknown" }, headers: auth(@owner_token)
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
  end

  test "same-Human applications discover only their own Local and shared machines" do
    first = connect_agent_session(steward: @owner, agent_identifier: "first-app")
    second = connect_agent_session(steward: @owner, agent_identifier: "second-app")
    first_runner = first.executor_access_token.executor
    second_runner = second.executor_access_token.executor
    [first_runner, second_runner].each do |executor|
      assert_predicate executor.announce(services: { "agent" => { "tools" => [] },
        "runner" => { "tools" => [] } }), :accepted?
    end
    shared = runner("shared-machine")
    assert_equal [first_runner.public_id, shared.public_id], listed_ids(first.access_secret)
    assert_equal [second_runner.public_id, shared.public_id], listed_ids(second.access_secret)
    assert_equal [shared.public_id], listed_ids(@owner_token)
    get "/agent_api/v1/executors/#{second_runner.public_id}", headers: auth(first.access_secret)
    assert_response :not_found
    get "/agent_api/v1/executors/#{first_runner.public_id}", headers: auth(first.access_secret)
    assert_response :success
    assert_nil response.parsed_body.dig("executor", "assignment_scope")
    assert_equal first.access_token.user.public_id, response.parsed_body.dig("executor", "agent_public_id")
  end

  test "application discovery batches ownership reads for the collection" do
    first = connect_agent_session(steward: @owner, agent_identifier: "query-app-one")
    connect_agent_session(steward: @owner, agent_identifier: "query-app-two")
    ApplicationRecord.uncached do
      assert_queries_match(/SELECT "users"\.\* FROM "users" WHERE "users"\."id" IN/, count: 1) do
        get "/agent_api/v1/executors", params: { kind: "agent" }, headers: auth(first.access_secret)
        assert_response :success
      end
    end
  end

  test "the document carries the announced declarations whole, the environment, the documents, and presence beside the contact sample" do
    NexusServer.register
    executor = runner("described")
    executor.update!(last_seen_at: 2.minutes.ago)
    executor.mark_connected("socket-1")

    get "/agent_api/v1/executors/#{executor.public_id}", headers: auth(@owner_token)
    assert_response :success
    document = response.parsed_body.fetch("executor")
    assert_equal executor.public_id, document.fetch("public_id")
    assert_equal "runner", document.fetch("kind")
    assert_equal "described", document.fetch("display_name")
    assert_equal "active", document.fetch("status")
    assert_equal "user_private", document.fetch("assignment_scope")
    assert_equal [ENTRY], document.dig("services", "runner", "tools")
    assert_equal ENVIRONMENT, document.dig("services", "runner", "environment")
    assert_equal [DOCUMENT], document.dig("services", "runner", "documents"), "the documents it can load, beside the tools"
    assert_equal "online", document.fetch("presence")
    assert_equal executor.reload.last_seen_at.iso8601, document.fetch("last_seen_at")
    assert_equal executor.connected_at.iso8601, document.fetch("connected_at")
    assert_not document.key?("credential_epoch"), "the transport fact stays on the self-read"

    executor.clear_connected("socket-1")
    get "/agent_api/v1/executors", params: { role: "runner" }, headers: auth(@owner_token)
    assert_equal "offline", response.parsed_body.fetch("executors").sole.fetch("presence")
  end

  test "show conceals an ineligible or unknown id as absence" do
    private_runner = runner("owner-private")

    get "/agent_api/v1/executors/#{private_runner.public_id}", headers: auth(@member_token)
    assert_response :not_found
    get "/agent_api/v1/executors/#{SecureRandom.uuid_v7}", headers: auth(@owner_token)
    assert_response :not_found
  end

  test "presence never filters: an offline eligible runner is listed" do
    offline = runner("offline")
    offline.update!(last_seen_at: 1.hour.ago)

    get "/agent_api/v1/executors", params: { role: "runner" }, headers: auth(@owner_token)
    row = response.parsed_body.fetch("executors").sole
    assert_equal offline.public_id, row.fetch("public_id")
    assert_equal "offline", row.fetch("presence")
  end

  # Readiness is a page-sized projection over the loaded rows, one query for
  # the listing, never one per executor.
  test "the listing reads credential readiness once for every addressable executor" do
    runner("one", scope: :account_wide)
    runner("two", scope: :account_wide)

    assert_queries_match(/access_tokens\.credential_epoch/, count: 1) do
      get "/agent_api/v1/executors", params: { role: "runner" }, headers: auth(@owner_token)
    end
    assert_equal 2, response.parsed_body.fetch("executors").length
  end

  test "the listing batches manager eligibility without changing scope or shutdown filtering" do
    curator = users(:curator)
    assert_equal :role_changed, curator.change_role(to: :admin)
    assert_equal :role_changed, @member.change_role(to: :admin)

    own = runner("own-private")
    shared = runner("curator-wide", manager: curator, scope: :account_wide, kind: :tool_provider)
    runner("member-private", manager: @member)
    pending = runner("member-wide", manager: @member, scope: :account_wide)
    runner("no-credential").revoke_credentials
    runner("revoked").revoke

    # Authentication, managers, application owners and their stewards each use one
    # bounded read, including rows this principal cannot address.
    ApplicationRecord.uncached do
      assert_queries_match(/FROM "users"/, count: 4) do
        assert_equal [own.public_id, shared.public_id, pending.public_id], listed_ids(@owner_token, {})
      end
    end

    assert_equal :removed, @member.remove
    assert_equal :restored, @member.restore

    ApplicationRecord.uncached do
      assert_queries_match(/FROM "users"/, count: 3) do
        assert_equal [own.public_id, shared.public_id], listed_ids(@owner_token, {}),
          "restoring a manager does not acknowledge the executor's pending shutdown"
      end
    end
  end
end
