require "test_helper"

class TaskExecutor::AgentPrivateTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @manager = users(:owner)
    @agent = users(:agent)
    @runner = connect_runner(manager: @manager, assignment_agent: @agent).executor_access_token.task_executor
  end

  test "private assignment serves its paired Agent and named Agents while preserving their principals" do
    instance = named_agent(scope: :instance)
    published = named_agent(scope: :steward)
    sibling = create_agent_member(steward: @manager)

    [@agent, instance, published].each { |principal| assert @runner.eligible_for?(principal) }
    [sibling, @manager, users(:member), users(:system)].each { |principal| refute @runner.eligible_for?(principal) }
    assert_nil @runner.agent
    assert_equal @agent, @runner.assignment_agent
    assert_equal @agent, instance.application_owner
    refute_equal instance, @agent
  end

  test "a named Agent's removal or steward transfer ends its new Runner access" do
    removed = named_agent(scope: :instance)
    transferred = named_agent(scope: :steward)
    removed.remove
    assert_equal :changed, transferred.change_steward(to: users(:member))

    refute @runner.eligible_for?(removed)
    refute @runner.eligible_for?(transferred)
    assert @runner.eligible_for?(@agent)
  end

  test "paired Agent removal ends private admission without revoking the independent Runner" do
    named = named_agent(scope: :steward)
    epoch = @runner.credential_epoch
    @agent.remove

    refute @runner.reload.eligible_for?(@agent)
    refute @runner.eligible_for?(named)
    assert_predicate @runner, :active?
    assert @runner.transport_authorized_at?(epoch)
  end

  test "paired Agent steward transfer does not move its old Runner to another Human" do
    named = named_agent(scope: :steward)
    epoch = @runner.credential_epoch
    assert_equal :changed, @agent.change_steward(to: users(:member))

    refute @runner.reload.eligible_for?(@agent)
    refute @runner.eligible_for?(named)
    assert_equal @manager, @runner.manager
    assert @runner.transport_authorized_at?(epoch)
  end

  test "assignment binding and scope cannot change through an ordinary model write or re-pair" do
    assert_raises(ActiveRecord::ReadonlyAttributeError) { @runner.assignment_agent = create_agent_member }
    assert_raises(ActiveRecord::ReadonlyAttributeError) { @runner.assignment_scope = :user_private }
    @runner.re_pair(display_name: "Reconnected")

    assert_equal @agent, @runner.reload.assignment_agent
    assert_predicate @runner, :agent_private?
  end

  test "only a Runner in agent_private scope may name an active paired Agent under its manager" do
    attributes = { account: @account, manager: @manager, display_name: "Private runner",
      registration_identifier: "new-private", executor_kind: :runner, assignment_scope: :agent_private,
      assignment_agent: @agent }
    assert TaskExecutor.new(attributes).valid?
    [
      { assignment_agent: nil },
      { assignment_agent: @manager },
      { assignment_agent: named_agent(scope: :instance) },
      { assignment_agent: create_agent_member(steward: users(:member)) },
      { executor_kind: :tool_provider },
      { assignment_scope: :user_private },
      { assignment_scope: :account_wide },
    ].each do |invalid|
      refute TaskExecutor.new(attributes.merge(invalid)).valid?, invalid.keys.inspect
    end
    @agent.remove
    refute TaskExecutor.new(attributes).valid?
  end

  private

    def named_agent(scope:)
      @account.users.create!(kind: :agent, role: :member, steward: @manager,
        display_name: "Named #{scope}", agent_identifier: "#{@agent.agent_identifier}/#{scope}",
        derived_from: @agent, definition_scope: scope, description: "Named worker")
    end
end
