require "test_helper"

class Workspace::AccessTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  test "an active Human reaches owned and account-wide Workspaces only" do
    curator = users(:curator)
    member = users(:member)

    assert_includes Workspace.data_accessible_to(curator), workspaces(:shared)
    assert_includes Workspace.data_accessible_to(curator), workspaces(:personal)
    assert_not_includes Workspace.data_accessible_to(curator), workspaces(:dedicated)

    assert_includes Workspace.data_accessible_to(member), workspaces(:shared)
    assert_not_includes Workspace.data_accessible_to(member), workspaces(:personal)

    assert workspaces(:personal).data_accessible_by?(curator)
    assert_not workspaces(:personal).data_accessible_by?(member)
    assert workspaces(:shared).data_accessible_by?(member)
    assert_not workspaces(:dedicated).data_accessible_by?(member)
  end

  test "a suspended Human loses the whole relation immediately, ownership included" do
    curator = users(:curator)
    assert_equal :suspended, curator.suspend

    assert_empty Workspace.data_accessible_to(curator.reload)
    assert_not workspaces(:personal).data_accessible_by?(curator)
  end

  test "an Agent derives exactly its current live steward's data access" do
    agent = users(:agent)

    accessible = Workspace.data_accessible_to(agent)
    assert_includes accessible, workspaces(:shared)
    assert_includes accessible, workspaces(:dedicated)
    assert_not_includes accessible, workspaces(:personal)

    assert workspaces(:dedicated).data_accessible_by?(agent)
    assert_not workspaces(:personal).data_accessible_by?(agent)
  end

  test "an Agent with a non-live steward has no data access" do
    agent = create_agent_member(steward: users(:member), agent_identifier: "w3-derived")
    assert_equal :suspended, users(:member).suspend

    assert_empty Workspace.data_accessible_to(agent.reload)
    assert_not workspaces(:shared).data_accessible_by?(agent)
  end

  test "the system user never receives a data surface" do
    assert_empty Workspace.data_accessible_to(users(:system))
    assert_not workspaces(:shared).data_accessible_by?(users(:system))
  end

  test "the dedication fence stops mismatched Agent writes but never reads or Humans" do
    dedicated = workspaces(:dedicated)
    matching = users(:agent)
    mismatched = create_agent_member(steward: users(:owner), agent_identifier: "w3-other")

    assert_not dedicated.dedication_fenced_against?(matching)
    assert dedicated.dedication_fenced_against?(mismatched)
    assert_not dedicated.dedication_fenced_against?(users(:owner))

    # The mismatched Agent still reads through its steward; only writes fence.
    assert dedicated.data_accessible_by?(mismatched)
    assert_not dedicated.data_writable_by?(mismatched)
    assert dedicated.data_writable_by?(matching)
    assert dedicated.data_writable_by?(users(:owner))

    # An untagged Workspace fences nobody.
    assert_not workspaces(:shared).dedication_fenced_against?(mismatched)
  end

  test "writability composes live state, access, and the fence" do
    shared = workspaces(:shared)

    assert shared.data_writable_by?(users(:member))

    shared.update_columns(state: "archiving")
    assert_not shared.data_writable_by?(users(:member))

    shared.update_columns(state: "restoring")
    assert shared.data_writable_by?(users(:member))
  end

  test "management is active-Human-owner-only" do
    assert workspaces(:personal).manageable_by?(users(:curator))
    assert_not workspaces(:personal).manageable_by?(users(:owner))
    assert_not workspaces(:personal).manageable_by?(users(:member))
    assert_not workspaces(:dedicated).manageable_by?(users(:agent))
    assert_not workspaces(:shared).manageable_by?(users(:system))

    assert_equal :suspended, users(:curator).suspend
    assert_not workspaces(:personal).manageable_by?(users(:curator).reload)
  end
end

# THE FENCE READS THE ROOT IDENTIFIER: an instance-scoped named definition answers where its
# declarer answers; a published row is no program and is never fenced — on a default install the
# workspace is dedicated, so without this clause `publish` would mint a row nobody could spawn.
class WorkspaceAccessNamedDefinitionsTest < ActiveSupport::TestCase
  CONFIGURATION = {
    tool_definitions: [], approval_mode: nil, approval_rules: nil, prompt_mechanism: "default",
    prompt_template: nil, compaction_policy: nil, default_model: nil,
  }.freeze

  def declare(caller, name, scope)
    Users::DeclareNamedDefinition.call(caller: caller, name: name, scope: scope, description: "#{name}.",
      configuration: CONFIGURATION).user
  end

  test "an instance row is fenced exactly as its declarer; a published row is admitted everywhere it reads" do
    dedicated = workspaces(:dedicated)
    matching = users(:agent)
    mismatched = create_agent_member(steward: users(:owner), agent_identifier: "w3-other")
    own_instance = declare(matching, "reviewer", "instance")
    other_instance = declare(mismatched, "reviewer", "instance")
    published_elsewhere = declare(mismatched, "docs", "steward")

    assert_equal matching.agent_identifier, own_instance.root_identifier
    assert_equal mismatched.agent_identifier, other_instance.root_identifier
    assert_not dedicated.dedication_fenced_against?(own_instance)
    assert dedicated.dedication_fenced_against?(other_instance)
    assert_not dedicated.dedication_fenced_against?(published_elsewhere)

    assert dedicated.answerer_eligible?(own_instance)
    assert_not dedicated.answerer_eligible?(other_instance)
    assert dedicated.answerer_eligible?(published_elsewhere), "spawnable in the spawner's own dedicated workspace"
    assert workspaces(:shared).answerer_eligible?(other_instance), "an untagged room fences nobody"
  end
end
