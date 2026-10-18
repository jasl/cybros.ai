require "test_helper"

class Workspaces::UpdateMessagingTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @sender = users(:agent)
    @recipient = create_agent_member(steward: users(:owner), agent_identifier: "messaging-target")
  end

  test "the owner replaces the policy and clearing restores default messaging" do
    before = @workspace.lock_version
    result = replace(agents: [agent_policy])

    assert_equal :updated, result.outcome
    assert_equal before + 1, result.workspace.lock_version
    assert_equal @recipient.public_id, @workspace.reload.messaging_policy.agents.sole.agent_public_id

    result = replace(agents: [])

    assert_equal :updated, result.outcome
    assert_empty @workspace.reload.messaging_policy.agents
  end

  test "sender IDs are normalized as a set and self may be explicitly included" do
    result = replace(agents: [agent_policy.merge(
      agent_public_id: @recipient.public_id.upcase,
      allowed_sender_public_ids: [@sender.public_id.upcase, @sender.public_id, @recipient.public_id]
    )])

    assert_equal :updated, result.outcome
    entry = @workspace.reload.messaging_policy.agents.sole
    assert_equal @recipient.public_id, entry.agent_public_id
    assert_equal [@sender.public_id, @recipient.public_id], entry.allowed_sender_public_ids
  end

  test "a duplicate recipient refuses the entire replacement" do
    original = @workspace.messaging_policy
    result = replace(agents: [agent_policy, agent_policy.merge(agent_public_id: @recipient.public_id.upcase)])

    assert_equal :invalid, result.outcome
    assert_equal original, @workspace.reload.messaging_policy
  end

  test "an explicit Public policy retains the allowlist for a later Private replacement" do
    result = replace(agents: [agent_policy.merge(mode: "public")])

    assert_equal :updated, result.outcome
    policy = @workspace.reload.messaging_policy.agents.sole
    assert_equal "public", policy.mode
    assert_equal [@sender.public_id], policy.allowed_sender_public_ids

    result = replace(agents: [policy.attributes.merge("mode" => "private")])

    assert_equal :updated, result.outcome
    assert_equal "private", @workspace.reload.messaging_policy.agents.sole.mode
    assert_equal [@sender.public_id], @workspace.messaging_policy.agents.sole.allowed_sender_public_ids
  end

  test "missing and unknown modes reject the entire replacement" do
    [agent_policy.except(:mode), agent_policy.merge(mode: "restricted")].each do |entry|
      assert_equal :invalid, replace(agents: [entry]).outcome
      assert_empty @workspace.reload.messaging_policy.agents
    end
  end

  test "only the active Human owner may replace messaging policy" do
    [users(:member), users(:curator), @sender, users(:system)].each do |actor|
      assert_equal :not_workspace_owner, replace(by: actor).outcome
    end
    @workspace = workspaces(:personal)
    assert_equal :suspended, users(:curator).suspend

    assert_equal :not_workspace_owner, replace(by: users(:curator).reload).outcome
    assert_empty @workspace.reload.messaging_policy.agents
  end

  test "Account administrator status does not manage somebody else's Workspace" do
    personal = workspaces(:personal)

    result = Workspaces::UpdateMessaging.call(
      workspace: personal, by: users(:owner), agents: [agent_policy], lock_version: personal.lock_version
    )

    assert_equal :not_workspace_owner, result.outcome
    assert_empty personal.reload.messaging_policy.agents
  end

  test "nonactive Workspaces reject edits and tombstones are absent" do
    %w[archiving archived restoring].each do |state|
      @workspace.update_columns(state: state)
      assert_equal :workspace_not_active, replace.outcome, state
    end
    %w[deleting deleted].each do |state|
      @workspace.update_columns(state: state)
      assert_equal :not_found, replace.outcome, state
    end
  end

  test "the existing Workspace version protects other edits from stale policy writes" do
    stale_version = @workspace.lock_version
    @workspace.update!(name: "A newer name")

    result = replace(lock_version: stale_version)

    assert_equal :stale_object, result.outcome
    assert_equal "A newer name", @workspace.reload.name
    assert_empty @workspace.messaging_policy.agents
  end

  test "an unchanged replacement still rejects an intervening policy edit" do
    another_editor = Workspace.find(@workspace.id)
    another_editor.update!(messaging_policy: { agents: [agent_policy] })

    result = replace(agents: [])

    assert_equal :stale_object, result.outcome
    assert_equal @recipient.public_id, @workspace.reload.messaging_policy.agents.sole.agent_public_id
  end

  test "an unchanged replacement advances the Workspace version" do
    before = @workspace.lock_version

    result = replace(agents: [])

    assert_equal :updated, result.outcome
    assert_equal before + 1, @workspace.reload.lock_version
    assert_empty @workspace.messaging_policy.agents
  end

  test "unknown profiles and Humans cannot be named as either end" do
    [SecureRandom.uuid_v7, users(:owner).public_id, users(:system).public_id].each do |public_id|
      assert_equal :invalid, replace(agents: [agent_policy.merge(agent_public_id: public_id)]).outcome
      @workspace.reload
      assert_equal :invalid, replace(agents: [agent_policy.merge(allowed_sender_public_ids: [public_id])]).outcome
      @workspace.reload
    end

    assert_empty @workspace.messaging_policy.agents
  end

  test "invalid UUIDs are rejected before persistence" do
    result = replace(agents: [agent_policy.merge(allowed_sender_public_ids: ["@fixture-agent"])])

    assert_equal :invalid, result.outcome
    assert_empty @workspace.reload.messaging_policy.agents
  end

  test "identity policies may retain unavailable Agents without granting them access" do
    @recipient.update_columns(status: "removed")
    result = replace

    assert_equal :updated, result.outcome
    assert_equal @recipient.public_id, @workspace.reload.messaging_policy.agents.sole.agent_public_id
    assert_equal [@sender.public_id], @workspace.messaging_policy.agents.sole.allowed_sender_public_ids
    assert_not @workspace.data_accessible_by?(@recipient.reload)
  end

  test "policy size uses the shared envelope bound without partial persistence" do
    oversized = agent_policy.merge(allowed_sender_public_ids: Array.new(2_000) { SecureRandom.uuid_v7 })
    result = replace(agents: [oversized])

    assert_equal :invalid, result.outcome
    assert result.errors.of_kind?(:messaging_policy_document, Nexus::SizeBounds::REJECTION)
    assert_empty @workspace.reload.messaging_policy.agents
  end

  private

    def agent_policy
      { agent_public_id: @recipient.public_id, mode: "private", allowed_sender_public_ids: [@sender.public_id] }
    end

    def replace(by: users(:owner), agents: [agent_policy], lock_version: @workspace.lock_version)
      Workspaces::UpdateMessaging.call(
        workspace: @workspace, by: by, agents: agents, lock_version: lock_version
      )
    end
end
