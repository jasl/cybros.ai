require "test_helper"

class WorkspaceTest < ActiveSupport::TestCase
  test "name is required and bounded" do
    workspace = workspaces(:shared)

    assert_not workspace.update(name: "")
    assert_not workspace.update(name: "a" * (Workspace::NAME_MAX_LENGTH + 1))
    assert workspace.update(name: "Renamed")
  end

  test "account, creator, public id, and agent identifier are create-frozen" do
    workspace = workspaces(:dedicated)

    assert_raises ActiveRecord::ReadonlyAttributeError do
      workspace.update(creator: users(:member))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      workspace.update(public_id: SecureRandom.uuid_v7)
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      workspace.update(agent_identifier: "someone-else")
    end
  end

  test "owner must be a Human User" do
    workspace = accounts(:cybros).workspaces.build(
      creator: users(:owner), owner: users(:agent), name: "Agent Owned"
    )

    assert_not workspace.valid?
    assert workspace.errors.of_kind?(:owner, :not_eligible)
  end

  test "creator is a Human or an Agent member, never the system user" do
    workspace = accounts(:cybros).workspaces.build(
      creator: users(:system), owner: users(:owner), name: "System Made"
    )

    assert_not workspace.valid?
    assert workspace.errors.of_kind?(:creator, :not_eligible)
  end

  test "access mode and state accept only their closed vocabularies" do
    workspace = workspaces(:shared)

    workspace.access_mode = "public"
    assert_not workspace.valid?
    assert workspace.errors.of_kind?(:access_mode, :inclusion)

    workspace = workspaces(:shared).reload
    workspace.state = "limbo"
    assert_not workspace.valid?
    assert workspace.errors.of_kind?(:state, :inclusion)
  end

  test "metadata must be a JSON object" do
    workspace = workspaces(:shared)

    assert_not workspace.update(metadata: "text")
    assert workspace.errors.of_kind?(:metadata, :invalid)

    assert_not workspace.reload.update(metadata: [1, 2])
    assert workspace.errors.of_kind?(:metadata, :invalid)

    # The jsonb type normalizes symbol keys at assignment; the model sees a
    # JSON object, never a rejection.
    assert workspace.reload.update(metadata: { labels: %w[research] })
    assert_equal({ "labels" => %w[research] }, workspace.reload.metadata)
  end

  test "metadata has a dedicated 2 KiB canonical JSON bound" do
    workspace = workspaces(:shared)
    bound = Nexus::SizeBounds.fetch(:workspace_metadata_bound)
    at_bound = { "k" => "a" * (bound - 8) }
    over_bound = { "k" => "a" * (bound - 7) }

    assert_equal bound, Nexus::SizeBounds.json_bytesize(at_bound)
    assert workspace.update(metadata: at_bound)
    assert_not workspace.reload.update(metadata: over_bound)
    assert workspace.errors.of_kind?(:metadata, :content_too_large)
  end

  # ── the provider override opt-in ──────────────────────────────

  def memory_names = Nexus::ToolRegistry.wire_names_in("nexus.memory")

  test "tool provider overrides default to an empty map and are a JSON object under their own 2 KiB bound" do
    created = Workspaces::Create.call(creator: users(:owner), name: "Fresh").workspace
    assert_equal({}, created.tool_provider_overrides)

    workspace = workspaces(:shared)
    assert_not workspace.update(tool_provider_overrides: "text")
    assert workspace.errors.of_kind?(:tool_provider_overrides, :invalid)

    bound = Nexus::SizeBounds.fetch(:tool_provider_overrides_bound)
    assert_equal Nexus::SizeBounds.fetch(:workspace_metadata_bound), bound
    over_bound = { "nexus.memory" => "a" * bound }
    assert_not workspace.reload.update(tool_provider_overrides: over_bound)
    assert workspace.errors.of_kind?(:tool_provider_overrides, :content_too_large)
  end

  test "every key is an overridable live namespace and every value a live tools provider of the account" do
    workspace = workspaces(:shared)
    provider = connect_provider(identifier: "mem", tools: memory_names)

    assert workspace.update(tool_provider_overrides: { "nexus.memory" => provider.public_id })
    assert_equal({ "nexus.memory" => provider.public_id }, workspace.reload.tool_provider_overrides)

    assert_not workspace.update(tool_provider_overrides: { "nexus.graph" => provider.public_id })
    assert workspace.errors.of_kind?(:tool_provider_overrides, :namespace_not_overridable)
    assert_not workspace.reload.update(tool_provider_overrides: { "rho.coding" => provider.public_id })
    assert workspace.errors.of_kind?(:tool_provider_overrides, :namespace_not_overridable)
    # The source-routed namespace: live and announceable, never a workspace's to override — a skill
    # load is routed per call by its name's announcer.
    assert_not workspace.reload.update(tool_provider_overrides: { "nexus.skill" => provider.public_id })
    assert workspace.errors.of_kind?(:tool_provider_overrides, :namespace_not_overridable)
    assert_nil workspace.reload.tool_provider_override_for("skill")

    assert_not workspace.reload.update(tool_provider_overrides: { "nexus.memory" => SecureRandom.uuid_v7 })
    assert workspace.errors.of_kind?(:tool_provider_overrides, :provider_unknown)
    assert_not workspace.reload.update(tool_provider_overrides: { "nexus.memory" => suite_runner.public_id })
    assert workspace.errors.of_kind?(:tool_provider_overrides, :provider_unknown), "a runner-kind row is no provider"

    # Cleared first: re-assigning the map the row already holds is no
    # change, and the snapshot rule re-judges nothing (the case below).
    assert workspace.reload.update(tool_provider_overrides: {})
    provider.revoke
    assert_not workspace.update(tool_provider_overrides: { "nexus.memory" => provider.public_id })
    assert workspace.errors.of_kind?(:tool_provider_overrides, :provider_unknown), "a revoked provider is not live"
  end

  # The value is a SNAPSHOT: validated when the column changes, never re-judged on an unrelated save
  # after the provider is gone.
  test "the override is a snapshot: a rename after the provider is revoked still saves" do
    workspace = workspaces(:shared)
    provider = connect_provider(identifier: "mem", tools: memory_names)
    assert workspace.update(tool_provider_overrides: { "nexus.memory" => provider.public_id })

    provider.revoke
    assert workspace.reload.update(name: "Renamed under a dead provider")
    assert_equal({ "nexus.memory" => provider.public_id }, workspace.reload.tool_provider_overrides)
  end

  # The two lock-free readers: a reserved or non-kernel name never consults
  # the map (risk 1), and the row reader is not filtered by status — a
  # revoked provider is named so addressing can say why it refuses.
  test "tool_provider_override_for answers the namespace's provider for overridable names only" do
    workspace = workspaces(:shared)
    provider = connect_provider(identifier: "mem", tools: memory_names)
    assert_nil workspace.tool_provider_override_for("memory_read")
    assert_nil workspace.tool_provider_for("memory_read")

    assert workspace.update(tool_provider_overrides: { "nexus.memory" => provider.public_id })
    assert_equal provider.public_id, workspace.tool_provider_override_for("memory_read")
    assert_equal provider.public_id, workspace.tool_provider_override_for("nexus.memory.read")
    assert_equal provider, workspace.tool_provider_for("memory_read")
    assert_nil workspace.tool_provider_override_for("wait"), "reserved"
    assert_nil workspace.tool_provider_override_for("spawn"), "reserved, in its wire spelling"
    assert_nil workspace.tool_provider_override_for("read_file"), "not a kernel name"
    assert_nil workspace.tool_provider_for("wait")

    provider.revoke
    assert_equal provider, workspace.reload.tool_provider_for("memory_read"),
      "the row reader names a revoked provider; addressing refuses it with the honest detail"
  end

  # One ladder, two names: the store host's contract and the override writer read the same body.
  test "write_refusal is store_write_refusal's ladder under the general name" do
    workspace = workspaces(:dedicated)
    fenced = create_agent_member(steward: users(:owner), agent_identifier: "someone-else")

    assert_nil workspace.write_refusal(users(:owner))
    assert_nil workspace.write_refusal(users(:agent))
    assert_equal :workspace_agent_identifier_mismatch, workspace.write_refusal(fenced)
    assert_equal :not_found, workspace.write_refusal(users(:member))
    assert_equal workspace.store_write_refusal(fenced), workspace.write_refusal(fenced)

    workspace.update_columns(state: "archived", archived_at: Time.current)
    assert_equal :workspace_not_active, workspace.reload.write_refusal(users(:owner))
  end

  test "metadata rejects exponent-form floats before jsonb persistence" do
    workspace = workspaces(:shared)

    assert_not workspace.update(metadata: { "value" => 1e308 })
    assert workspace.errors.of_kind?(:metadata, :unsupported_number)
    assert_equal({}, workspace.reload.metadata)
  end

  test "an Agent creator requires its own identifier while every other creator requires nil" do
    human_tagged = accounts(:cybros).workspaces.build(
      creator: users(:owner), owner: users(:owner),
      name: "Human Tagged", agent_identifier: "fixture-agent-installation"
    )
    assert_not human_tagged.valid?
    assert human_tagged.errors.of_kind?(:agent_identifier, :not_allowed)

    foreign_tagged = accounts(:cybros).workspaces.build(
      creator: users(:agent), owner: users(:owner),
      name: "Foreign Tagged", agent_identifier: "someone-else"
    )
    assert_not foreign_tagged.valid?
    assert foreign_tagged.errors.of_kind?(:agent_identifier, :not_allowed)

    agent_untagged = accounts(:cybros).workspaces.build(
      creator: users(:agent), owner: users(:owner), name: "Agent Untagged"
    )
    assert_not agent_untagged.valid?
    assert agent_untagged.errors.of_kind?(:agent_identifier, :not_allowed)
  end

  test "visibility projections follow the state lattice" do
    workspace = workspaces(:shared)

    {
      "active" => [true, true, false],
      "archiving" => [false, true, false],
      "archived" => [false, true, false],
      "restoring" => [true, true, false],
      "deleting" => [false, false, true],
      "deleted" => [false, false, true],
    }.each do |state, (live, browsable, tombstoned)|
      workspace.state = state

      assert_equal live, workspace.live?, state
      assert_equal browsable, workspace.browsable?, state
      assert_equal tombstoned, workspace.tombstoned?, state
      assert_equal !tombstoned, workspace.non_tombstoned?, state
    end
  end

  test "state scopes partition the table like the predicates" do
    workspaces(:personal).update_columns(state: "archived", archived_at: Time.current)
    workspaces(:dedicated).update_columns(state: "deleting", deleted_at: Time.current)

    assert_includes Workspace.live, workspaces(:shared)
    assert_not_includes Workspace.live, workspaces(:personal)
    assert_includes Workspace.browsable, workspaces(:personal)
    assert_not_includes Workspace.browsable, workspaces(:dedicated)
    assert_includes Workspace.tombstoned, workspaces(:dedicated)
    assert_not_includes Workspace.non_tombstoned, workspaces(:dedicated)
  end
end
