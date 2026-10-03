require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# Admission and steward reassignment share PrincipalLocks' Agent-before-Human
# order. These tests force each legal winner rather than relying on thread
# timing, then assert which steward may become the Attempt's payer.
class ModelInvocations::AdmitQueuedWorkStewardRaceTest < ActiveJob::TestCase
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @source = users(:member)
    @target = users(:owner)
    DevModelLane.ensure_enabled!(@account)
    @agent = create_agent_member(
      steward: @source,
      agent_identifier: "admission-steward-race-#{SecureRandom.hex(4)}"
    )
    selection = DevModelLane.selection(workload: "text_generation", account: @account)
    @one_shot = OneShot.create!(
      account: @account,
      workspace: workspaces(:shared),
      creating_user: @agent,
      workload: selection.workload
    )
    @invocation = DevModelLane.create_invocation!(one_shot: @one_shot, selection: selection)
  end

  teardown do
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: @invocation.id).delete_all
    ModelInvocation.where(id: @invocation.id).delete_all
    OneShot.where(id: @one_shot.id).delete_all
    User.where(id: @agent.id).delete_all
  end

  test "admission first freezes the steward current under the Agent lock" do
    held_agent = hold_row_lock(User, @agent.id)
    admission = start_database_call { ModelInvocations::AdmitQueuedWork.call }
    wait_until_transitively_blocked_by(held_agent.pid, admission.pid)
    reassignment = start_database_call do
      User.find(@agent.id).change_steward(to: User.find(@target.id))
    end
    wait_until_transitively_blocked_by(held_agent.pid, admission.pid, reassignment.pid)

    release_row_lock(held_agent)
    held_agent = nil
    admission_result = finish_database_call(admission)
    admission = nil
    reassignment_result = finish_database_call(reassignment)
    reassignment = nil

    admitted = admission_result.admitted.find { _1.invocation.id == @invocation.id }
    assert_not_nil admitted
    assert_equal @agent.public_id, admitted.attempt.consumer_public_id
    assert_equal @source.public_id, admitted.attempt.payer_public_id
    assert_equal :changed, reassignment_result
    assert_equal @target, @agent.reload.steward
  ensure
    release_row_lock(held_agent) if held_agent
    stop_database_call(admission) if admission
    stop_database_call(reassignment) if reassignment
  end

  test "steward reassignment first makes stale admission wait for rediscovery" do
    held_agent = hold_row_lock(User, @agent.id)
    reassignment = start_database_call do
      User.find(@agent.id).change_steward(to: User.find(@target.id))
    end
    wait_until_transitively_blocked_by(held_agent.pid, reassignment.pid)
    admission = start_database_call { ModelInvocations::AdmitQueuedWork.call }
    wait_until_transitively_blocked_by(held_agent.pid, reassignment.pid, admission.pid)

    release_row_lock(held_agent)
    held_agent = nil
    reassignment_result = finish_database_call(reassignment)
    reassignment = nil
    stale_result = finish_database_call(admission)
    admission = nil

    assert_equal :changed, reassignment_result
    assert_empty stale_result.admitted
    assert_equal 1, stale_result.rejected
    assert_equal "queued", @invocation.reload.status
    assert_empty @invocation.attempts

    retried = ModelInvocations::AdmitQueuedWork.call.admitted
      .find { _1.invocation.id == @invocation.id }
    assert_not_nil retried
    assert_equal @agent.public_id, retried.attempt.consumer_public_id
    assert_equal @target.public_id, retried.attempt.payer_public_id
  ensure
    release_row_lock(held_agent) if held_agent
    stop_database_call(reassignment) if reassignment
    stop_database_call(admission) if admission
  end
end
