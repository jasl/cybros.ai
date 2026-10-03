require "test_helper"

class Conversations::Turns::ConvergeDeliverableTest < ActiveJob::TestCase
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
  end

  test "settling a long loop reads its designated answer without instantiating completed history" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    seam = create_loop_backed_turn(conversation: conversation, acting_user: @human)
    grow!(seam.agent_loop, ask("answer"))
    AgentLoops::ScheduleReady.call(agent_loop_id: seam.agent_loop.id)
    answer = seam.agent_loop.agent_loop_nodes.find_by!(node_key: "answer")
    result = AgentLoops::Parks::Settle.call(
      node: answer, claim_token: answer.resolution_token,
      outcome: "completed", content: "the final answer"
    )
    assert_predicate result, :applied?
    assert_equal "completed", seam.agent_loop.reload.status
    add_history(seam.agent_loop, 1_000)
    clear_enqueued_jobs

    instantiated = count_node_instances do
      result = Conversations::Turns::Converge.call(
        conversation_id: conversation.id, agent_loop_id: seam.agent_loop.id
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

    def add_history(agent_loop, count)
      now = Time.current
      AgentLoopNode.insert_all!(Array.new(count) do |index|
        {
          account_id: agent_loop.account_id, agent_loop_id: agent_loop.id,
          node_key: "history-#{index}", type: AgentLoopNodes::ToolTask.sti_name,
          status: "completed", on_failure: "absorb", authored_by: "model",
          transcript_visibility: "collapsed", completed_at: now, created_at: now, updated_at: now,
          tool_name: "read_file", tool_input: {}, timeout_ms: 600_000,
        }
      end)
    end

    def count_node_instances(&block)
      count = 0
      subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
        count += payload.fetch(:record_count) if payload.fetch(:class_name) == "AgentLoopNode"
      end
      ApplicationRecord.uncached(&block)
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
