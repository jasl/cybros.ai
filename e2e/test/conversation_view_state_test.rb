require_relative "conversation_turn_test"

class ConversationTurnTest
  def test_hidden_restored_and_deleted_turns_update_the_follower_and_undo_keeps_the_host_usable
    boot_rho!
    conversation, loop_id = rho_open("!mock -- this answer can be hidden")
    chat = steward_conversation(conversation)
    await_rho_loop(loop_id, "completed")
    original = await_settled_reply(chat).items.last
    await("rho reading the original answer") { view_follower(conversation)["text"] == original.text }

    hidden = after_view_change(chat, conversation, "visibility") do
      chat.turns.set_view_state(original.public_id, visibility: "hidden")
    end
    assert_empty hidden.fetch("text")
    assert_equal original.public_id, hidden.fetch("turn")
    assert_equal loop_id, hidden.fetch("run_public_id"), "hiding content does not remove execution identity"
    assert_empty chat.turns.list.items

    visible = after_view_change(chat, conversation, "visibility") do
      chat.turns.set_view_state(original.public_id, visibility: "visible")
    end
    assert_equal original.text, visible.fetch("text")

    side = chat.fork(side: true, idempotency_key: SecureRandom.uuid).conversation
    child = steward_conversation(side.public_id)
    concealed = after_view_change(chat, conversation, "soft_delete") do
      chat.turns.set_view_state(original.public_id, concealed: true)
    end
    assert_empty concealed.fetch("text")
    assert_equal loop_id, concealed.fetch("run_public_id")
    assert_empty chat.turns.list.items
    assert_equal [original.text], child.turns.list.items.map(&:text), "the fork retains its own view"

    restored = after_view_change(chat, conversation, "soft_delete") do
      chat.turns.set_view_state(original.public_id, concealed: false)
    end
    assert_equal original.text, restored.fetch("text")
    child.delete
    deleted = after_view_change(chat, conversation, "turn_deleted") { chat.turns.delete(original.public_id) }
    assert_empty deleted.fetch("text")
    assert_nil deleted["turn"]
    assert_nil deleted["run_public_id"]
    assert_empty deleted.fetch("tasks")
    assert_equal conversation, deleted.fetch("public_id"), "undo keeps the conversation followed"

    sent = @daemon.control(:post, "/say", body: {
      "public_id" => conversation, "text" => "!mock -- after undo", "delivery_mode" => "queue",
    })
    refute_nil sent.dig("input", "public_id"), sent.inspect
    replacement = await_settled_reply(chat).items.last
    refute_equal original.public_id, replacement.public_id
    assert_operator replacement.position, :>, original.position
    refute_equal loop_id, replacement.active_variant.run_public_id
    followed = await_follower(conversation, loop: replacement.active_variant.run_public_id)
    assert_equal replacement.public_id, followed.fetch("turn")
  end

  private

    def view_follower(conversation)
      @daemon.control(:get, "/followers").fetch("followers").find { |row| row.fetch("public_id") == conversation }
    end

    def after_view_change(chat, conversation, type)
      before = chat.events(limit: 200).items.last.cursor
      yield
      event = await("the #{type} change on the durable feed") do
        chat.events(after: before, limit: 200).find { |item| item.type == type }
      end
      await("rho consuming the #{type} change") do
        row = view_follower(conversation)
        row if row.fetch("sequence") >= event.sequence
      end
    end
end
