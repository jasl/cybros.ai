require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# Two mail passes on one loop, on committed rows with real PostgreSQL lock waits. Duplicate passes are
# ordinary — the quiescence site and the sweep both enqueue one — and their convergence contract is the
# hosted receipt: the loser of a tip's key settles on the winner's receipt and goes on to the next tip.
# The loser's accept saved the conversation inside the transaction its receipt rolled back, and the
# pass reuses that conversation object for its next tip.
class AgentRuns::ResultDeliveryRaceTest < ActiveSupport::TestCase
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @seam = create_run_backed_turn(conversation: @conversation, acting_user: @human, turn_status: "completed",
      variant_status: "completed")
    @agent_run = @seam.agent_run
    @agent_run.update!(delivered_at: Time.current)
    @first = background_tip("bg1", status: "completed")
    @second = background_tip("bg2", status: "queued")
  end

  teardown do
    if @seam
      ConversationCommandReceipt.where(host: @conversation).delete_all
      ConversationEventItem.where(host: @conversation).delete_all
      ConversationEvent.where(host: @conversation).delete_all
      ConversationEventCursor.where(host: @conversation).delete_all
      AgentRuns::Reap.destroy_aggregate(AgentRun.find(@agent_run.id))
      @conversation.reload.destroy!
    end
  end

  # A detached tool row the loop's wake would deliver, passive so its mail is a message and needs no
  # model surface.
  def background_tip(key, status:)
    node = @agent_run.agent_run_tasks.create!(
      node_key: key, type: "AgentRunTasks::ToolTask", tool_name: "read", tool_input: {},
      authored_by: "model", detached: true, wake: "passive"
    )
    node.update_columns(status: status, completed_at: (Time.current if status == "completed"))
    node
  end

  def mail_pass = start_database_call { AgentRuns::ResultDelivery.call(AgentRun.find(@agent_run.id)) }

  # The pass that read only the first tip queues first; the second tip settles; the pass that read both
  # queues behind it. The first wins the first tip's key, so the second loses that key and must still
  # mail the second tip — through the same conversation object its rolled-back accept had saved.
  test "a pass that loses one tip's receipt mails the next tip, and every tip is mailed once" do
    held = hold_row_lock(Conversation, @conversation.id)
    earlier = mail_pass
    wait_until_waiting_on_lock(earlier.pid)
    @second.update_columns(status: "completed", completed_at: Time.current)
    later = mail_pass
    wait_until_waiting_on_lock(later.pid)
    release_row_lock(held)

    assert_equal [:delivered], finish_database_call(earlier)
    assert_equal [:delivered, :delivered], finish_database_call(later), "the loser replays the first tip and mails the second"

    inputs = @conversation.conversation_inputs.where(origin: AgentRuns::ResultDelivery::ORIGIN)
    assert_equal 2, inputs.count, "one row per tip, never two"
    keys = ConversationCommandReceipt.where(host: @conversation).pluck(:idempotency_key)
    assert_equal ["mail:#{@agent_run.public_id}:bg1", "mail:#{@agent_run.public_id}:bg2"], keys.sort
    assert [@first, @second].all? { |tip| tip.reload.result_delivered_at }, "both tips are stamped"
  end
end
