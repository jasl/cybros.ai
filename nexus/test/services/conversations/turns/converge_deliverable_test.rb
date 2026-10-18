require "test_helper"

class Conversations::Turns::ConvergeDeliverableTest < ActiveJob::TestCase
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
  end

  test "settling a long loop reads its designated answer without instantiating completed history" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
    grow!(seam.run, ask("answer"))
    Runs::ScheduleReady.call(run_id: seam.run.id)
    answer = seam.run.tasks.find_by!(node_key: "answer")
    result = Runs::Parks::Settle.call(
      node: answer, claim_token: answer.resolution_token,
      outcome: "completed", content: "the final answer"
    )
    assert_predicate result, :applied?
    assert_equal "completed", seam.run.reload.status
    add_history(seam.run, 1_000)
    clear_enqueued_jobs

    instantiated = count_node_instances do
      result = Conversations::Turns::Converge.call(
        conversation_id: conversation.id, run_id: seam.run.id
      )
      assert_equal 1, result.value[:recorded]
    end

    assert_equal "completed", seam.turn.reload.status
    assert_equal "the final answer", seam.variant.content_bodies.find_by!(role: "content").effective_text
    assert_equal "the final answer", seam.variant.reload.content_preview
    assert_nil conversation.reload.active_turn_id
    assert_operator instantiated, :<=, 1,
      "adopting one answer must not instantiate 1,000 completed tasks"
  end

  private

    def add_history(run, count)
      now = Time.current
      Task.insert_all!(Array.new(count) do |index|
        {
          account_id: run.account_id, run_id: run.id,
          node_key: "history-#{index}", type: Tasks::ToolTask.sti_name,
          status: "completed", on_failure: "absorb", authored_by: "model",
          transcript_visibility: "collapsed", completed_at: now, created_at: now, updated_at: now,
          tool_name: "read_file", tool_input: {}, timeout_ms: 600_000,
        }
      end)
    end

    def count_node_instances(&block)
      count = 0
      subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
        count += payload.fetch(:record_count) if payload.fetch(:class_name) == "Task"
      end
      ApplicationRecord.uncached(&block)
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
