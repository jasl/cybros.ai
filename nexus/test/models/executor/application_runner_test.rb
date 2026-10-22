require "test_helper"

class Executor::ApplicationRunnerTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @manager = users(:owner)
    connection = connect_agent_session(steward: @manager, agent_identifier: "local-owner")
    @application = connection.executor_access_token.executor
    @agent = @application.agent
    @application.announce(services: { "agent" => { "tools" => [] }, "runner" => { "tools" => [] } })
  end

  test "runner capability belongs to the application family without changing the principal" do
    instance = named_agent(scope: :instance)
    published = named_agent(scope: :steward)
    [@agent, instance, published].each { |principal| assert @application.eligible_for_role?(:runner, principal) }
    [create_agent_member(steward: @manager), @manager, users(:member), users(:system)].each do |principal|
      refute @application.eligible_for_role?(:runner, principal)
    end
    assert_equal @agent, instance.application_owner
    refute_equal instance, @agent
    assert_nil @application.assignment_scope
  end

  test "removal or steward transfer of a named Agent ends admission through its old application" do
    removed = named_agent(scope: :instance)
    transferred = named_agent(scope: :steward)
    removed.remove
    assert_equal :changed, transferred.change_steward(to: users(:member))
    refute @application.eligible_for_role?(:runner, removed)
    refute @application.eligible_for_role?(:runner, transferred)
    assert @application.eligible_for_role?(:runner, @agent)
  end

  test "withdrawal and restoration of runner capability keep the address and credential epoch" do
    id = @application.public_id
    epoch = @application.credential_epoch
    assert_predicate @application.announce(services: { "agent" => { "tools" => [] } }), :accepted?
    refute @application.eligible_for_role?(:runner, @agent)
    assert @application.eligible_for_role?(:agent, @agent)
    assert_predicate @application.announce(services: { "agent" => { "tools" => [] }, "runner" => { "tools" => [] } }), :accepted?
    assert @application.eligible_for_role?(:runner, @agent)
    assert_equal id, @application.reload.public_id
    assert_equal epoch, @application.credential_epoch
  end

  private

    def named_agent(scope:)
      @account.users.create!(kind: :agent, role: :member, steward: @manager,
        display_name: "Named #{scope}", agent_identifier: "#{@agent.agent_identifier}/#{scope}",
        derived_from: @agent, named_agent_scope: scope, description: "Named worker")
    end
end
