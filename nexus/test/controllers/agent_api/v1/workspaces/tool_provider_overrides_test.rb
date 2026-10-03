require "test_helper"

# PUT …/workspaces/{ws}/tool_provider_overrides: the opt-in door. A whole replacement under the
# workspace's CAS; write standing under the dedication fence; three lock-free 422s —
# `reserved_namespace` (ONE code with the announcement door), `provider_not_eligible` (the scope
# rule) and `provider_incomplete` (the completeness rule) — and a read that names the provider so a
# person can see why.
class AgentAPI::V1::Workspaces::ToolProviderOverridesTest < ActionDispatch::IntegrationTest
  include AgentMembershipTestHelper

  setup do
    @owner = create_access_token_fixture(user: users(:owner), name: "Owner")
    @curator = create_access_token_fixture(user: users(:curator), name: "Curator")
    @memory_names = Nexus::ToolRegistry.wire_names_in("nexus.memory")
    @shared = workspaces(:shared)
  end

  def bearer(fixture) = { "Authorization" => "Bearer #{fixture.secret}" }
  def bearer_secret(secret) = { "Authorization" => "Bearer #{secret}" }
  def path(workspace) = agent_api_v1_workspace_tool_provider_overrides_path(workspace.public_id)

  def put!(workspace, overrides, headers: bearer(@owner), lock_version: workspace.reload.lock_version)
    put path(workspace), headers: headers, as: :json,
      params: { tool_provider_overrides: { overrides: overrides, lock_version: lock_version } }
  end

  def provider(identifier: "mem", **over) = connect_provider(identifier: identifier, tools: @memory_names, **over)

  test "the PUT replaces the map, bumps lock_version and renders the provider on the Full projection" do
    provider = provider()
    before = @shared.lock_version

    put!(@shared, { "nexus.memory" => provider.public_id })
    assert_response :success
    workspace = response.parsed_body.fetch("workspace")
    assert_equal before + 1, workspace.fetch("lock_version")
    assert_equal({ "nexus.memory" => {
      "provider_public_id" => provider.public_id, "display_name" => "Provider mem",
      "assignment_scope" => "account_wide",
    } }, workspace.fetch("tool_provider_overrides"))

    get agent_api_v1_workspace_path(@shared.public_id), headers: bearer(@owner)
    assert_response :success
    assert_equal provider.public_id,
      response.parsed_body.dig("workspace", "tool_provider_overrides", "nexus.memory", "provider_public_id")
  end

  test "stale is 409 stale_object; a missing lock_version is 400" do
    provider = provider()
    put!(@shared, { "nexus.memory" => provider.public_id }, lock_version: 99)
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")

    put path(@shared), headers: bearer(@owner), as: :json,
      params: { tool_provider_overrides: { overrides: { "nexus.memory" => provider.public_id } } }
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
  end

  # ── the scope rule (brief correction (g)) ──

  test "a user_private provider on an account-wide workspace is 422 provider_not_eligible" do
    provider = provider(manager: users(:owner), assignment_scope: :user_private)
    put!(@shared, { "nexus.memory" => provider.public_id })
    assert_response :unprocessable_entity
    assert_equal "provider_not_eligible", response.parsed_body.dig("error", "code")
    assert_equal({}, @shared.reload.tool_provider_overrides)
  end

  test "a user_private provider under another Human is 422 provider_not_eligible on a private workspace" do
    provider = provider(manager: users(:owner), assignment_scope: :user_private)
    put!(workspaces(:personal), { "nexus.memory" => provider.public_id }, headers: bearer(@curator))
    assert_response :unprocessable_entity
    assert_equal "provider_not_eligible", response.parsed_body.dig("error", "code")
  end

  test "a user_private provider managed by the owner of a private workspace is admitted" do
    provider = provider(manager: users(:owner), assignment_scope: :user_private)
    put!(workspaces(:dedicated), { "nexus.memory" => provider.public_id })
    assert_response :success
    assert_equal "user_private",
      response.parsed_body.dig("workspace", "tool_provider_overrides", "nexus.memory", "assignment_scope")
  end

  test "five of six names is 422 provider_incomplete" do
    partial = connect_provider(identifier: "partial", tools: @memory_names - ["memory_grep"])
    put!(@shared, { "nexus.memory" => partial.public_id })
    assert_response :unprocessable_entity
    assert_equal "provider_incomplete", response.parsed_body.dig("error", "code")
  end

  test "a reserved namespace is 422 reserved_namespace; an unknown one is 422 validation_failed" do
    provider = provider()
    put!(@shared, { "nexus.graph" => provider.public_id })
    assert_response :unprocessable_entity
    assert_equal "reserved_namespace", response.parsed_body.dig("error", "code")

    put!(@shared, { "rho.coding" => provider.public_id })
    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_includes response.parsed_body.dig("error", "message"), "rho.coding"
  end

  test "a value that is not a string is 400 parameter_invalid; an absent overrides key is 400" do
    put!(@shared, { "nexus.memory" => { "id" => "x" } })
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")

    put path(@shared), headers: bearer(@owner), as: :json,
      params: { tool_provider_overrides: { lock_version: @shared.lock_version } }
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
  end

  # ── standing: write standing under the fence, not ownership ──

  test "a fenced agent is 403; the dedicated agent's own PUT is 200; a transport credential is 401" do
    provider = provider()
    dedicated = workspaces(:dedicated)
    fenced = connect_agent_session(steward: users(:owner), agent_identifier: "another-program")
    put!(dedicated, { "nexus.memory" => provider.public_id }, headers: bearer_secret(fenced.access_secret))
    assert_response :forbidden
    assert_equal "workspace_agent_identifier_mismatch", response.parsed_body.dig("error", "code")

    own = connect_agent_session(steward: users(:owner), agent_identifier: users(:agent).agent_identifier)
    put!(dedicated, { "nexus.memory" => provider.public_id }, headers: bearer_secret(own.access_secret))
    assert_response :success
    assert_equal({ "nexus.memory" => provider.public_id }, dedicated.reload.tool_provider_overrides)

    put!(dedicated, {}, headers: bearer_secret(own.executor_access_secret))
    assert_response :unauthorized
  end

  test "the empty map clears, and the read names a revoked provider until it does" do
    provider = provider()
    put!(@shared, { "nexus.memory" => provider.public_id })
    assert_response :success

    provider.revoke
    get agent_api_v1_workspace_path(@shared.public_id), headers: bearer(@owner)
    assert_equal "Provider mem",
      response.parsed_body.dig("workspace", "tool_provider_overrides", "nexus.memory", "display_name"),
      "revoked, not reaped: the snapshot still names it and its calls fail tool_not_served"

    put!(@shared, {})
    assert_response :success
    assert_equal({}, response.parsed_body.dig("workspace", "tool_provider_overrides"))
    assert_equal({}, @shared.reload.tool_provider_overrides)
  end
end
