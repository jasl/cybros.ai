require "test_helper"
require_relative "../../../test_helpers/row_lock_test_helper"

# The converger against a loop-locked narrator, on committed rows with real PostgreSQL lock waits:
# the hosted event plane carries no FK to the conversation, so a narration under the loop lock takes
# no KEY SHARE on a conversation row the converger holds FOR UPDATE — the ABBA r1 feared cannot
# form. The cursor is the one row both touch, and it ranks last on both paths, so it serialises them
# without a cycle.
class Conversations::Turns::ConvergeRaceTest < ActiveSupport::TestCase
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @seam = create_loop_backed_turn(conversation: @conversation, acting_user: @human)
  end

  teardown do
    if @seam
      AgentLoops::Reap.destroy_aggregate(AgentLoop.find(@seam.agent_loop.id))
      @conversation.reload.destroy!
    end
  end

  def narrate_under_the_loop_lock(status)
    start_database_call do
      agent_loop = AgentLoop.find(@seam.agent_loop.id)
      agent_loop.with_lock do
        AgentLoops::Transition.agent_loop(agent_loop, status: status, paused_at: Time.current)
      end
      agent_loop.status
    end
  end

  test "a loop-locked narration lands while the converger holds the conversation" do
    held = hold_row_lock(Conversation, @conversation.id)
    narrating = narrate_under_the_loop_lock("paused")

    assert_equal "paused", finish_database_call(narrating),
      "the narrator never waited on the conversation row: no FK, no KEY SHARE"
    assert_predicate held.thread, :alive?, "and the converger's lock was still held"
    release_row_lock(held)

    assert_equal ["turn_status"], @conversation.conversation_event_items.pluck(:item_type)
  end

  test "the cursor serialises a converger's narration and a scheduler's without a cycle" do
    cursor = ConversationEventCursor.create_or_find_by!(host: @conversation)
    # The converger's shape: conversation held FOR UPDATE, then the cursor
    # taken by its own narration and held to commit.
    held = hold_row_lock(Conversation, @conversation.id, before_commit: lambda { |conversation|
      ConversationEvent::Append.call(host: conversation, items: [{
        type: "turn_status", payload: { "turn_public_id" => @seam.turn.public_id, "status" => "failed" },
      }])
    })
    cursor_holder = start_database_call do
      ApplicationRecord.transaction do
        ConversationEventCursor.lock.find(cursor.id)
        sleep 0.2
        :held
      end
    end
    narrating = narrate_under_the_loop_lock("paused")
    wait_until_waiting_on_lock(narrating.pid)
    assert_equal :held, finish_database_call(cursor_holder)

    assert_equal "paused", finish_database_call(narrating)
    release_row_lock(held)

    items = @conversation.conversation_event_items.order(:sequence)
    assert_equal %w[turn_status turn_status], items.pluck(:item_type)
    assert_equal [1, 2], items.pluck(:sequence), "one cursor, contiguous, no cycle"
  end
end
