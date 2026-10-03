require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "a human display name is required and bounded" do
    user = users(:member)

    assert_not user.update(display_name: "")
    assert_not user.update(display_name: "a" * (User::DISPLAY_NAME_MAX_LENGTH + 1))
  end

  test "an Agent User requires its program-provided display name" do
    user = accounts(:cybros).users.build(
      kind: :agent,
      role: :member,
      steward: users(:owner),
      display_name: nil,
      agent_identifier: "waiting-program"
    )

    assert_not user.valid?
    assert user.errors.of_kind?(:display_name, :blank)
  end

  test "an ordinary Agent User is always a member" do
    user = accounts(:cybros).users.build(
      kind: :agent,
      role: :admin,
      steward: users(:owner),
      display_name: "Program supplied",
      agent_identifier: "admin-agent"
    )

    assert_not user.valid?
    assert user.errors.of_kind?(:role, :agent_must_be_member)
  end

  test "the system display name remains ordinarily mutable" do
    system = users(:system)

    assert system.update(display_name: "Kernel")
    assert_not system.update(display_name: nil)
  end

  test "a human member requires an identity" do
    user = accounts(:cybros).users.build(kind: :human, role: :member, display_name: "No Identity")

    assert_not user.valid?
    assert user.errors.of_kind?(:identity, :blank)
  end

  test "an agent member must not carry an identity" do
    user = accounts(:cybros).users.build(
      kind: :agent, role: :member, display_name: "Agent", identity: identities(:member)
    )

    assert_not user.valid?
    assert user.errors.of_kind?(:identity, :present)
  end

  test "the owner role is human-only" do
    user = accounts(:cybros).users.build(kind: :agent, role: :owner, display_name: "Agent Owner")

    assert_not user.valid?
    assert user.errors.of_kind?(:role, :owner_must_be_human)
  end

  test "the system role is agent-kind" do
    user = accounts(:cybros).users.build(
      kind: :human, role: :system, display_name: "Fake System", identity: identities(:member)
    )

    assert_not user.valid?
    assert user.errors.of_kind?(:role, :system_must_be_agent)
  end

  test "members scope excludes the synthetic system user" do
    members = accounts(:cybros).users.members

    assert_includes members, users(:owner)
    assert_includes members, users(:member)
    assert_not_includes members, users(:system)
  end

  test "admin? covers the owner transparently" do
    assert users(:owner).admin?
    assert_not users(:member).admin?
  end

  # The Human a principal's work answers to: the mirror of TaskExecutor's `controlling_human_id_of`,
  # and the row memory's `user/` rung is anchored on. The system user answers nil — it has no
  # steward.
  test "controlling_human is the steward for an agent, self for a human, nil for the system user" do
    assert_equal users(:owner), users(:agent).controlling_human
    assert_equal users(:member), users(:member).controlling_human
    assert_nil users(:system).controlling_human
  end

  test "an identity holds at most one membership" do
    duplicate = accounts(:cybros).users.build(
      kind: :human, role: :member, display_name: "Duplicate", handle: "duplicate", identity: identities(:member)
    )

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end
end
