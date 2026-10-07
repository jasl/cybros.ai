require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class Schedules::DispatchRaceTest < ActiveSupport::TestCase
  include RowLockTestHelper

  uses_transaction :test_two_workers_waiting_at_the_same_parent_create_one_occurrence,
    :test_cancel_winning_the_parent_arbiter_prevents_a_waiting_dispatch,
    :test_dispatch_winning_the_parent_arbiter_leaves_cancel_an_exact_waiting_input_to_remove

  setup do
    DevModelLane.ensure_enabled!(accounts(:cybros))
    @user = users(:member)
    @parent = Conversation.create!(workspace: workspaces(:shared), creating_user: @user, answering_user: users(:agent))
    @cutoff = DatabaseClock.now + 60
    result = Schedules::Create.call(conversation: @parent, creating_user: @user, attributes: {
      prompt: "Check status", provider_id: "dev", model_ref: "mock-text", tool_names: [],
      rule: { "kind" => "interval", "starts_at" => @cutoff.iso8601(6), "every_seconds" => 60 },
    })
    assert_predicate result, :accepted?
    @job = result.value
    @calls = []
  end

  teardown do
    release_row_lock(@held) if @held
    @calls.each { |call| stop_database_call(call) }
    @job.execution_conversations.each(&:destroy!)
    @parent.destroy!
  end

  test "two workers waiting at the same parent create one occurrence" do
    @held = hold_row_lock(Conversation, @parent.id)
    2.times { @calls << start_database_call { dispatch } }
    wait_until_transitively_blocked_by(@held.pid, *@calls.map(&:pid))
    release_barrier
    results = @calls.map { |call| finish_database_call(call) }

    assert_equal [:dispatched, :not_due], results.sort
    assert_equal 1, @job.execution_conversations.count
    assert_equal 1, @job.execution_conversations.sole.conversation_inputs.count
  end

  test "cancel winning the parent arbiter prevents a waiting dispatch" do
    @held = hold_row_lock(Conversation, @parent.id, before_commit: ->(_parent) { cancel })
    @calls << start_database_call { dispatch }
    wait_until_transitively_blocked_by(@held.pid, @calls.sole.pid)
    release_barrier

    assert_equal :not_due, finish_database_call(@calls.sole)
    assert_empty @job.execution_conversations
    assert_predicate @job.reload, :canceled?
  end

  test "dispatch winning the parent arbiter leaves cancel an exact waiting input to remove" do
    @held = hold_row_lock(Conversation, @parent.id, before_commit: ->(_parent) { dispatch })
    @calls << start_database_call { cancel }
    wait_until_transitively_blocked_by(@held.pid, @calls.sole.pid)
    release_barrier

    assert_predicate finish_database_call(@calls.sole), :accepted?
    assert_predicate @job.reload, :canceled?
    child = @job.execution_conversations.sole
    assert_empty child.conversation_inputs
    assert_equal 1, child.conversation_event_items.where(item_type: "input_deleted").count
  end

  private

    def dispatch = Schedules::Dispatch.call(id: @job.id, cutoff: @cutoff)

    def cancel = Schedules::Manage.transition(Schedule.find(@job.id), :cancel, by: User.find(@user.id))

    def release_barrier
      release_row_lock(@held)
      @held = nil
    end
end
