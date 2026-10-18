require "test_helper"
require_relative "../test_helpers/lock_order_test_helper"

class DeploymentsLockOrderTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  test "maintenance resumes parked runs before locking prepared invocations" do
    run = seed(ask("gate"), workspace: workspaces(:shared), creating_user: users(:member))
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: users(:member)))
    Runs::ScheduleReady.call(run_id: run.id)
    _, invocation = create_invocation(status: "running")
    invocation.attempts.create!(account: accounts(:cybros), ordinal: 1,
      admission_shape: "admitted_free", deadline_at: 10.minutes.from_now)
    Deployments::Maintenance.prepare

    sequences = assert_ladder_order("deployment maintenance resume") { Deployments::Maintenance.resume }

    assert_includes sequences.map(&:uniq), %w[runs model_invocations]
    assert_not_includes sequences.flatten, "accounts"
    assert_not_includes sequences.flatten, "model_invocation_attempts"
    assert_not Deployments::Maintenance.active?
  end
end
