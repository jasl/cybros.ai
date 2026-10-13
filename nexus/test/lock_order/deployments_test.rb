require "test_helper"
require_relative "../test_helpers/lock_order_test_helper"

class DeploymentsLockOrderTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  test "maintenance resumes parked runs before locking prepared invocations" do
    agent_run = seed(ask("gate"), workspace: workspaces(:shared), creating_user: users(:member))
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: users(:member)))
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    _, invocation = create_invocation(status: "running")
    invocation.attempts.create!(account: accounts(:cybros), ordinal: 1,
      admission_shape: "admitted_free", deadline_at: 10.minutes.from_now)
    Deployments::Maintenance.prepare

    sequences = assert_ladder_order("deployment maintenance resume") { Deployments::Maintenance.resume }

    assert_includes sequences.map(&:uniq), %w[agent_runs model_invocations]
    assert_not_includes sequences.flatten, "accounts"
    assert_not_includes sequences.flatten, "model_invocation_attempts"
    assert_not Deployments::Maintenance.active?
  end
end
