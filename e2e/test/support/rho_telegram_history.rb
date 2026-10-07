module E2E
  # Channel controls project the kernel's real timeline and candidate deck. The
  # channel's forward cursor must not hide an answer regenerated at an old slot.
  module RhoTelegramHistory
    def test_telegram_history_search_lifecycle_and_view_state_stay_in_the_saved_route
      boot_runtime(allowed: [101, 102])
      marker = "history-#{SecureRandom.hex(6)}"
      @runtime.consume(update(1, "!mock reply=history-answer -- #{marker} public discussion"))
      chat = @workspace.conversation(current("101:0"))
      turn = completed_reply(chat)
      @runtime.consume(update(2, "!mock reply=private-answer -- #{marker} private discussion", user: 102, chat: 102))
      foreign = @workspace.conversation(current("102:0"))
      completed_reply(foreign)

      assert_includes telegram_control(3, "/rename Launch history"), "renamed"
      assert_equal "Launch history", chat.fetch.title
      history = telegram_control(4, "/history")
      assert_includes history, turn.public_id
      assert_includes history, "history-answer"
      search = telegram_control(5, "/search #{marker}")
      assert_includes search, chat.public_id
      refute_includes search, foreign.public_id
      refute_includes search, "private discussion"

      telegram_control(6, "/history exclude #{turn.public_id}")
      assert_equal "excluded_from_context", chat.turns.list.items.find { |row| row.public_id == turn.public_id }.visibility
      telegram_control(7, "/history include #{turn.public_id}")
      assert_includes telegram_control(8, "/history delete #{turn.public_id}"), "apex"
      telegram_control(9, "/history hide #{turn.public_id}")
      refute chat.turns.list.items.any? { |row| row.public_id == turn.public_id }
      telegram_control("show-history", "/history show #{turn.public_id}")
      assert chat.turns.list.items.any? { |row| row.public_id == turn.public_id }

      telegram_control(10, "/archive")
      refute_nil chat.fetch.archived_at
      telegram_control(11, "/new")
      selected = current("101:0")
      telegram_control(12, "/restore #{chat.public_id}")
      assert_nil chat.fetch.archived_at
      assert_equal selected, current("101:0")
      telegram_control(13, "/resume #{chat.public_id}")
      assert_equal chat.public_id, current("101:0")
      assert_equal 1, chat.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_empty @logs
    end

    def test_telegram_regeneration_delivers_a_new_candidate_once_after_restart_and_preserves_old_task_identity
      boot_runtime(allowed: [101, 102])
      sender = { user: 102, chat: 102 }
      @runtime.consume(update(1, "!mock reply=candidate-answer -- sample an answer", **sender))
      original_task = telegram_task_id(telegram_control("original-status", "/status", **sender))
      chat = @workspace.conversation(current("102:0"))
      original = completed_reply(chat)
      original_variant = original.active_variant.public_id
      refute_nil original.active_variant.memory_context
      await("the original formal answer") { tick; @telegram.formal(102).length == 1 }
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
        current if current&.active_variant&.public_id == candidate_id && current.status == "completed" && @telegram.formal(102).length == 2
      end
      assert_equal original.position, regenerated.position
      refute_equal original.active_variant.run_public_id, regenerated.active_variant.run_public_id
      assert_equal "Keep this current workspace state.\n", File.read(path)
      2.times { tick }
      assert_equal 2, @telegram.formal(102).length
      deck = chat.turns.variants(original.public_id).items
      assert_equal [original_variant, candidate_id].sort, deck.map(&:public_id).sort
      assert_includes telegram_control(3, "/status #{original_task}", **sender), original.active_variant.run_public_id
      assert_includes telegram_control(4, "/status #{candidate_id}", **sender), regenerated.active_variant.run_public_id
      assert_includes telegram_control(5, "/transcript #{candidate_id}", **sender), "candidate-answer"
      before = @telegram.calls.length
      @runtime.consume(update(6, "/context", **sender))
      assert await("the first chunk of the Telegram context preview") {
        tick
        @telegram.calls.drop(before).any? { |method, fields| method == "sendMessage" && fields[:text].start_with?("Context preview:") }
      }
      assert_equal 1, chat.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_empty @logs
    end

    def test_telegram_edit_candidate_fork_and_undo_keep_the_original_history_and_current_files
      boot_runtime(allowed: [101])
      @runtime.consume(update(1, "!mock reply=original-answer -- a retained premise"))
      chat = @workspace.conversation(current("101:0"))
      original = completed_reply(chat)
      assert_includes telegram_control(2, "/edit #{original.position} Manually corrected answer"), "Edited as a new candidate"
      edited = chat.turns.list.items.find { |row| row.public_id == original.public_id }
      assert_equal "Manually corrected answer", edited.active_variant.content
      assert_equal 2, chat.turns.variants(original.public_id).items.length
      telegram_control(3, "/variant #{original.position} #{original.active_variant.public_id}")
      assert_equal original.active_variant.public_id, chat.turns.list.items.find { |row| row.public_id == original.public_id }.active_variant.public_id

      path = File.join(@root, "project", "keep-after-fork.txt")
      File.write(path, "Keep the current files.\n")
      telegram_control(4, "/fork #{original.position}")
      child = @workspace.conversation(current("101:0"))
      refute_equal chat.public_id, child.public_id
      copied = child.turns.list.items.find { |row| row.position == original.position }
      refute_nil copied
      refute_equal original.public_id, copied.public_id
      refute copied.inherited
      assert_equal original.active_variant.content, copied.active_variant.content
      assert_equal "Keep the current files.\n", File.read(path)
      @runtime.consume(update(5, "!mock reply=branch-answer -- continue this fork"))
      branch = await("a completed local reply in the fork") do
        child.turns.list.items.find { |row| row.public_id != copied.public_id && !row.inherited && row.kind == "direct_reply" && row.status == "completed" }
      end
      assert_includes telegram_control(6, "/undo"), "Newest turn deleted"
      refute child.turns.list.items.any? { |row| row.public_id == branch.public_id }
      assert child.turns.list.items.any? { |row| row.public_id == copied.public_id }
      assert_equal 1, chat.turns.list.items.count { |row| row.kind == "direct_reply" }
      assert_equal "Keep the current files.\n", File.read(path)
      assert_empty @logs
    end
  end
end
