module E2E
  # Channel controls project the kernel's real timeline and candidate deck. The
  # channel's forward cursor must not hide an answer regenerated at an old slot.
  module RhoTelegramHistory
    def test_telegram_regeneration_delivers_a_new_candidate_once_after_restart_and_preserves_old_task_identity
      boot_runtime(allowed: [101, 102])
      sender = { user: 101, chat: 101 }
      receive(update(1, "!mock reply=candidate-answer -- sample an answer", **sender))
      original_task = telegram_task_id(telegram_control("original-status", "/status", **sender))
      chat = @workspace.conversation(current("101:0"))
      original = completed_reply(chat)
      original_variant = original.active_variant.public_id
      refute_nil original.active_variant.memory_context
      await("the original formal answer") { tick; @telegram.formal(101).length == 1 }
      path = File.join(@root, "project", "keep-after-regeneration.txt")
      File.write(path, "Keep this current workspace state.\n")

      receipt = telegram_control(2, "/regenerate #{original.position}", **sender)
      assert_includes receipt, "Regeneration started"
      candidate_id = telegram_task_id(receipt)
      refute_equal original_task, candidate_id
      refute_equal original_variant, candidate_id
      restart_group_runtime(allowed: [101, 102])
      regenerated = await("the regenerated candidate reaches the same old history position") do
        tick
        current = chat.turns.list.items.find { |row| row.public_id == original.public_id }
        current if current&.active_variant&.public_id == candidate_id && current.status == "completed" && @telegram.formal(101).length == 2
      end
      assert_equal original.position, regenerated.position
      refute_equal original.active_variant.run_public_id, regenerated.active_variant.run_public_id
      assert_equal "Keep this current workspace state.\n", File.read(path)
      2.times { tick }
      assert_equal 2, @telegram.formal(101).length
      deck = chat.turns.variants(original.public_id).items
      assert_equal [original_variant, candidate_id].sort, deck.map(&:public_id).sort
      assert_includes telegram_control(3, "/status #{original_task}", **sender), original.active_variant.run_public_id
      assert_includes telegram_control(4, "/status #{candidate_id}", **sender), regenerated.active_variant.run_public_id
      assert_includes telegram_control(5, "/transcript #{candidate_id}", **sender), "candidate-answer"
      before = @telegram.calls.length
      receive(update(6, "/context", **sender))
      assert await("the first chunk of the Telegram context preview") {
        tick
        @telegram.calls.drop(before).any? { |method, fields| method == "sendMessage" && fields[:text].start_with?("Context preview:") }
      }
      assert_equal 1, chat.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_empty @logs
    end
  end
end
