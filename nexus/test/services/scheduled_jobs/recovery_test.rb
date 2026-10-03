require "test_helper"
require_relative "../../test_helpers/lock_order_test_helper"

class ScheduledJobs::RecoveryTest < ActiveJob::TestCase
  include LockOrderTestHelper
  include ActiveSupport::Testing::ConstantStubbing

  NOW = Time.utc(2026, 10, 2)

  setup do
    @user = users(:member)
    @parent = Conversation.create!(workspace: workspaces(:shared), creating_user: @user, answering_user: users(:agent))
  end

  test "a blocked source consumes budget and the continuation reaches the next due job at the original cutoff" do
    blocked = create_job!
    other_parent = Conversation.create!(workspace: workspaces(:shared), creating_user: @user, answering_user: users(:agent))
    ready = create_job!(parent: other_parent)
    future = create_job!(parent: other_parent, starts_at: NOW + 120)
    assert_predicate Conversations::Archive.call(conversation: @parent), :accepted?

    stub_const(ScheduledJobs::DispatchDue, :BUDGET, 1) do
      first = ScheduledJobs::DispatchDue.call(cutoff: (NOW + 60).iso8601(6))
      assert_equal({ scanned: 1, dispatched: 0 }, first.counts)
      assert_predicate first, :more?
      assert_equal [(NOW + 60).iso8601(6), (NOW + 60).iso8601(6), blocked.id], first.cursor
      assert_enqueued_with(job: ScheduledJobs::DispatchDueJob, args: first.cursor) do
        ScheduledJobs::DispatchDueJob.perform_now((NOW + 60).iso8601(6))
      end

      second = ScheduledJobs::DispatchDue.call(cutoff: first.cursor[0], after_at: first.cursor[1], after_id: first.cursor[2])
      assert_equal({ scanned: 1, dispatched: 1 }, second.counts)
      assert_equal ready.id, second.cursor.last
      last = ScheduledJobs::DispatchDue.call(cutoff: second.cursor[0], after_at: second.cursor[1], after_id: second.cursor[2])
      assert_equal({ scanned: 0, dispatched: 0 }, last.counts)
      assert_not_predicate last, :more?
    end

    assert_equal "conversation_archived", blocked.reload.last_error_code
    assert_equal 1, ready.execution_conversations.count
    assert_empty future.execution_conversations
    assert_equal "ScheduledJobs::DispatchDueJob", recurring_schedule.fetch("dispatch_due_scheduled_jobs").fetch("class")
  end

  test "an exceptional source does not starve the rest of a recovery window" do
    poison = create_job!
    healthy = create_job!
    original = ScheduledJobs::Dispatch.method(:call)
    dispatch = ->(id:, cutoff:) do
      raise "unreadable source" if id == poison.id
      original.call(id: id, cutoff: cutoff)
    end

    result = ScheduledJobs::Dispatch.stub(:call, dispatch) do
      ScheduledJobs::DispatchDue.call(cutoff: (NOW + 60).iso8601(6))
    end
    assert_equal({ scanned: 2, dispatched: 1 }, result.counts)
    assert_equal healthy.id, result.cursor.last
    assert_empty poison.execution_conversations
    assert_equal 1, healthy.execution_conversations.count
  end

  test "dispatch and management use the existing conversation lock ladder" do
    job = create_job!
    assert_ladder_order("scheduled dispatch") do
      assert_equal :dispatched, ScheduledJobs::Dispatch.call(id: job.id, cutoff: NOW + 60)
    end
    assert_ladder_order("scheduled edit") do
      assert_predicate ScheduledJobs::Manage.revise(job.reload, { prompt: "Changed" }, by: @user,
        expected_lock_version: job.lock_version), :accepted?
    end
    assert_ladder_order("scheduled cancel") do
      assert_predicate ScheduledJobs::Manage.transition(job, :cancel, by: @user), :accepted?
    end
  end

  private

    def create_job!(parent: @parent, starts_at: NOW + 60)
      result = DatabaseClock.stub(:now, NOW) do
        ScheduledJobs::Create.call(conversation: parent, creating_user: @user, attributes: {
          prompt: "Check status", provider_id: "dev", model_ref: "mock-text", tool_names: [],
          rule: { "kind" => "interval", "starts_at" => starts_at.iso8601, "every_seconds" => 60 },
        })
      end
      assert_predicate result, :accepted?
      result.value
    end
end
