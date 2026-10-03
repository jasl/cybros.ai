require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# The narration gate and an authority cut serialize on the Invocation lock.
# These tests use committed rows and real PostgreSQL lock waits; timing cannot
# choose the winner for them. The lock-order suite separately pins the appender's
# full OneShot -> Invocation -> cursor descent.
class OneShotEvents::StreamSinkRaceTest < ActiveSupport::TestCase
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    selection = DevModelLane.selection(workload: "text_generation", account: @account)
    @one_shot = OneShot.create!(
      account: @account,
      workspace: workspaces(:shared),
      creating_user: @human,
      workload: selection.workload
    )
    @invocation = DevModelLane.create_invocation!(
      one_shot: @one_shot, selection: selection, status: "running"
    )
    @attempt = ModelInvocationAttempt.create!(
      account: @account,
      model_invocation: @invocation,
      ordinal: 1,
      admission_shape: "admitted_free",
      deadline_at: 10.minutes.from_now,
      provider_started_at: Time.current,
      status: "running",
      settlement_state: "pending",
      consumer_public_id: @human.public_id,
      payer_public_id: @human.public_id
    )
  end

  teardown do
    OneShots::Drain.call(one_shot_ids: [@one_shot.id]) if @one_shot&.persisted?
  end

  test "a cancellation that wins the invocation lock prevents a waiting delta" do
    held = hold_row_lock(
      ModelInvocation,
      @invocation.id,
      before_commit: ->(locked) {
        ModelInvocation::Cancellation.call(
          scope: ModelInvocation.where(id: locked.id),
          reason: "workspace_archived"
        )
      }
    )
    appending = start_database_call do
      attempt = ModelInvocationAttempt.find(@attempt.id)
      sink = OneShotEvents::StreamSink.new(attempt: attempt, flush_interval_ms: 0)
      sink.on_event(
        attempt.model_invocation,
        SimpleInference::Responses::Events::TextDelta.new(delta: "after the cut")
      )
    end

    wait_until_transitively_blocked_by(held.pid, appending.pid)

    release_row_lock(held)
    held = nil
    finish_database_call(appending)
    appending = nil

    assert_predicate @invocation.reload, :canceled?
    assert_empty OneShotEventItem.where(one_shot_id: @one_shot.id),
      "a delta must not commit after the authority cut"
  ensure
    release_row_lock(held) if held
    stop_database_call(appending) if appending
  end
end
