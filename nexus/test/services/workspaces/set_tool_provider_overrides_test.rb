require "test_helper"

# THE OPT-IN WRITER: a whole replacement of one column under the workspace's CAS, WRITE standing
# under the dedication fence (not ownership — an agent with write standing may opt its own workspace
# in), and three lock-free provider checks that are reads, never locks: a provider revoked between
# the read and the commit fails its calls `tool_not_served`.
class Workspaces::SetToolProviderOverridesTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  setup do
    @workspace = workspaces(:shared)
    @memory_names = Nexus::ToolRegistry.wire_names_in("nexus.memory")
  end

  def set(workspace: @workspace, by: users(:owner), overrides:, lock_version: workspace.lock_version)
    Workspaces::SetToolProviderOverrides.call(
      workspace: workspace, by: by, overrides: overrides, lock_version: lock_version
    )
  end

  def provider(identifier: "mem", **over)
    connect_provider(identifier: identifier, tools: @memory_names, **over)
  end

  test "a whole replacement persists the map and bumps lock_version; the empty map clears" do
    provider = provider()
    before = @workspace.lock_version

    result = set(overrides: { "nexus.memory" => provider.public_id })
    assert_equal :updated, result.outcome
    assert_equal({ "nexus.memory" => provider.public_id }, @workspace.reload.tool_provider_overrides)
    assert_equal before + 1, @workspace.lock_version
    assert_equal @workspace, result.workspace

    cleared = set(overrides: {})
    assert_equal :updated, cleared.outcome
    assert_equal({}, @workspace.reload.tool_provider_overrides)
    assert_equal before + 2, @workspace.lock_version
  end

  test "a wrong lock_version is stale, exactly as the metadata PATCH answers" do
    provider = provider()
    result = set(overrides: { "nexus.memory" => provider.public_id }, lock_version: 99)
    assert_equal :stale_object, result.outcome
    assert_equal({}, @workspace.reload.tool_provider_overrides)
  end

  # ONE code on both doors (brief correction (a)): the announcement door
  # spells it `reserved_namespace`, and so does the opt-in. Before any lock.
  test "a reserved namespace is refused reserved_namespace before any lock" do
    provider = provider()
    before = @workspace.lock_version
    %w[nexus.graph nexus.human nexus.conversation].each do |namespace|
      result = set(overrides: { namespace => provider.public_id })
      assert_equal :reserved_namespace, result.outcome, namespace
    end
    assert_equal before, @workspace.reload.lock_version, "no lock, no CAS, no bump"
    assert_equal({}, @workspace.tool_provider_overrides)
  end

  test "a namespace that is neither reserved nor overridable is the model's invalid" do
    provider = provider()
    result = set(overrides: { "rho.coding" => provider.public_id })
    assert_equal :invalid, result.outcome
    assert result.errors.of_kind?(:tool_provider_overrides, :namespace_not_overridable)
  end

  # ── the scope rule (brief correction (g)): the PUT admits what
  # `eligible_for?` answers true for EVERY principal of the workspace ──

  test "an account-wide provider is admitted on an account-wide workspace" do
    provider = provider(assignment_scope: :account_wide)
    assert_equal :updated, set(overrides: { "nexus.memory" => provider.public_id }).outcome
  end

  test "a user_private provider whose manager owns the private workspace is admitted" do
    dedicated = workspaces(:dedicated)
    assert_predicate dedicated, :private?
    provider = provider(manager: users(:owner), assignment_scope: :user_private)
    assert_equal users(:owner).id, dedicated.owner_id

    assert_equal :updated, set(workspace: dedicated, overrides: { "nexus.memory" => provider.public_id }).outcome
  end

  test "a user_private provider on an account-wide workspace is provider_not_eligible: it would darken other members" do
    provider = provider(manager: users(:owner), assignment_scope: :user_private)
    assert_predicate @workspace, :account_wide?

    result = set(overrides: { "nexus.memory" => provider.public_id })
    assert_equal :provider_not_eligible, result.outcome
    assert_equal({}, @workspace.reload.tool_provider_overrides)
  end

  test "a user_private provider under ANOTHER Human is refused on a private workspace too" do
    personal = workspaces(:personal)
    assert_equal users(:curator).id, personal.owner_id
    provider = provider(manager: users(:owner), assignment_scope: :user_private)

    result = set(workspace: personal, by: users(:curator), overrides: { "nexus.memory" => provider.public_id })
    assert_equal :provider_not_eligible, result.outcome
  end

  test "a provider announcing five of the six names is provider_incomplete" do
    partial = connect_provider(identifier: "partial", tools: @memory_names - ["memory_ls"])
    result = set(overrides: { "nexus.memory" => partial.public_id })
    assert_equal :provider_incomplete, result.outcome
    assert_equal({}, @workspace.reload.tool_provider_overrides)
  end

  # Another account's provider is the same miss as an unknown id: the read
  # is `find_by(account_id:, public_id:)`, and this world holds one account.
  test "a runner-kind row, a revoked provider and an unknown id are provider_not_eligible" do
    revoked = provider(identifier: "dead")
    revoked.revoke
    runner = connect_runner(manager: users(:owner), runner_identifier: "not-a-provider",
      assignment_scope: :account_wide).executor_access_token.task_executor

    { "revoked" => revoked.public_id, "runner" => runner.public_id,
      "unknown" => SecureRandom.uuid_v7 }.each do |label, id|
      assert_equal :provider_not_eligible, set(overrides: { "nexus.memory" => id }).outcome, label
    end
  end

  # ── the standing ladder, read on the LOCKED row (correction (d)) ──

  test "the ladder: a fenced agent, an archived workspace, a tombstoned one, a non-member" do
    provider = provider()
    dedicated = workspaces(:dedicated)
    fenced = create_agent_member(steward: users(:owner), agent_identifier: "another-program")

    assert_equal :workspace_agent_identifier_mismatch,
      set(workspace: dedicated, by: fenced, overrides: { "nexus.memory" => provider.public_id }).outcome

    assert_equal :not_found,
      set(workspace: workspaces(:personal), by: users(:member),
        overrides: { "nexus.memory" => provider.public_id }).outcome, "no access conceals like absence"

    @workspace.update_columns(state: "archived", archived_at: Time.current)
    assert_equal :workspace_not_active,
      set(overrides: { "nexus.memory" => provider.public_id }, lock_version: @workspace.reload.lock_version).outcome

    @workspace.update_columns(state: "deleted", deleted_at: Time.current)
    assert_equal :not_found,
      set(overrides: { "nexus.memory" => provider.public_id }, lock_version: @workspace.reload.lock_version).outcome
  end

  # The design's line, pinned on purpose: write standing, not ownership.
  test "an agent with write standing opts its own dedicated workspace in" do
    dedicated = workspaces(:dedicated)
    provider = provider()
    result = set(workspace: dedicated, by: users(:agent), overrides: { "nexus.memory" => provider.public_id })
    assert_equal :updated, result.outcome
    assert_equal({ "nexus.memory" => provider.public_id }, dedicated.reload.tool_provider_overrides)
  end
end
