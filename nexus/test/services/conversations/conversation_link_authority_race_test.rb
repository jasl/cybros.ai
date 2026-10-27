require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class Conversations::ConversationLinkAuthorityRaceTest < ActiveSupport::TestCase
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @human = users(:member)
    @sender = create_agent_member(display_name: "Grant sender")
    @recipient = create_agent_member(display_name: "Grant receiver")
    @source, @target = 2.times.map do
      Conversation.create!(workspace: workspaces(:shared), creating_user: @human, answering_user: @recipient)
    end
  end

  teardown do
    ConversationLink.where(first_conversation_id: @source.id).delete_all
    [@source, @target].each { |conversation| destroy_memory_owner!(conversation.reload) }
    [@sender, @recipient].each(&:destroy!)
  end

  test "revocation winning before grant admission leaves no active relation" do
    held = hold_row_lock(User, @sender.id, before_commit: ->(sender) { sender.remove })
    creating = start_database_call { create_link }
    wait_until_transitively_blocked_by(held.pid, creating.pid)
    release_row_lock(held)
    held = nil
    result = finish_database_call(creating)
    creating = nil
    assert_equal :answerer_not_eligible, result.outcome
    assert_empty ConversationLink.where(first_conversation_id: @source.id)
    assert_equal :restored, @sender.reload.restore
    assert create_link.accepted?
  ensure
    release_row_lock(held) if held
    stop_database_call(creating) if creating
  end

  test "grant admission winning before Agent revocation publishes only a closed relation" do
    held = hold_row_lock(Conversation, @source.id)
    creating = start_database_call { create_link }
    wait_until_transitively_blocked_by(held.pid, creating.pid)
    revoking = start_database_call { User.find(@sender.id).remove }
    wait_until_transitively_blocked_by(creating.pid, revoking.pid)
    release_row_lock(held)
    held = nil
    result = finish_database_call(creating)
    creating = nil
    assert result.accepted?, result.outcome.inspect
    assert_equal :removed, finish_database_call(revoking)
    revoking = nil
    assert_equal "principal_unavailable", result.value.reload.close_reason
    assert_equal :restored, @sender.reload.restore
    assert result.value.reload.closed?
    replacement = create_link
    assert replacement.accepted?, replacement.outcome.inspect
    refute_equal result.value.public_id, replacement.value.public_id
  ensure
    release_row_lock(held) if held
    stop_database_call(creating) if creating
    stop_database_call(revoking) if revoking
  end

  test "endpoint ACL narrowing winning before grant admission cannot be missed" do
    held = hold_row_lock(Conversation, @source.id, before_commit: ->(source) {
      result = Conversations::SetAccess.call(Conversations::SetAccess::Command.new(
        conversation: source, acting_user: @human, default: "none", entries: []))
      assert result.accepted?, result.outcome.inspect
    })
    creating = start_database_call { create_link }
    wait_until_transitively_blocked_by(held.pid, creating.pid)
    release_row_lock(held)
    held = nil
    result = finish_database_call(creating)
    creating = nil
    assert_equal :answerer_not_eligible, result.outcome
    assert_empty ConversationLink.where(first_conversation_id: @source.id)
  ensure
    release_row_lock(held) if held
    stop_database_call(creating) if creating
  end

  private

    def create_link
      Conversations::Links::Create.call(conversation: Conversation.find(@source.id), agent: User.find(@sender.id),
        peer_conversation: Conversation.find(@target.id), peer_agent: User.find(@recipient.id), acting_user: @human)
    end
end
