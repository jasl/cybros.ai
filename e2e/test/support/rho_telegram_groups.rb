module E2E
  # Group participants share a room's observed context while their work keeps
  # separate execution owners. Every input and control enters through Telegram.
  module RhoTelegramGroups
    def test_group_observation_settings_keep_owner_authority_and_exact_room_scope_after_restart
      boot_runtime(allowed: [101, 102, 103])
      model = self.class::MODEL
      conversations = @core.conversations.fetch("conversations").map { |row| row.fetch("public_id") }
      telegram_control(1, "/access chats add -20")
      enabled = update(2, "/observe on", chat: -10, topic: 7)
      @runtime.consume(enabled)
      assert_includes telegram_control(3, "/observe status", user: 102, chat: -10, topic: 7), "Observe: on"
      assert_includes telegram_control(4, "/observe", user: 103, chat: -10, topic: 7), "Observe: on"
      assert_includes telegram_control(5, "/observe off", user: 102, chat: -10, topic: 7), "Only the bot owner"

      telegram_control(6, "/model #{model}", chat: -10, topic: 7)
      owner_settings = telegram_control(7, "/settings", chat: -10, topic: 7)
      member_settings = telegram_control(8, "/settings", user: 102, chat: -10, topic: 7)
      [owner_settings, member_settings].each do |text|
        assert_includes text, "Group behavior:"
        assert_includes text, "Requests: explicit mentions or replies"
        assert_includes text, "Observe: on"
        assert_includes text, "Shared scope: this topic (7) in group -10."
        assert_includes text, "Your conversation settings"
      end
      assert_includes owner_settings, "Model: #{model}"
      assert_includes member_settings, "Model: rho default"
      assert_includes telegram_control(9, "/observe status", user: 102, chat: -10, topic: 8), "Observe: off"
      assert_includes telegram_control(10, "/observe status", user: 102, chat: -20, topic: 7), "Observe: off"
      assert_includes telegram_control(11, "/observe status", user: 102, chat: -10), "Observe: off"

      assert_equal conversations, @core.conversations.fetch("conversations").map { |row| row.fetch("public_id") }
      @runtime.consume(update(12, "The shared topic fact before restart", user: 102, chat: -10, topic: 7))
      @runtime.consume(update(13, "A different topic stays unobserved", user: 102, chat: -10, topic: 8))
      @runtime.consume(update(14, "Another allowed group stays unobserved", user: 102, chat: -20, topic: 7))
      @runtime.consume(update(15, "The group's non-topic room stays unobserved", user: 102, chat: -10))
      observer = group_observer
      observed = await("the topic's observation materializes without execution") do
        rows = observer.turns.list.items
        rows if rows.length == 1
      end
      assert_equal [observer.public_id], @core.conversations.fetch("conversations").map { |row| row.fetch("public_id") } - conversations
      assert_equal "The shared topic fact before restart", observed.first.active_variant.content
      assert_equal "message", observed.first.kind
      assert_equal "completed", observed.first.status
      assert_nil observed.first.active_variant.run_public_id
      assert_nil observed.first.active_variant.model
      assert_empty observer.inputs.list.items

      @state = telegram_state
      restart_group_runtime
      assert_includes telegram_control(16, "/observe status", user: 103, chat: -10, topic: 7), "Observe: on"
      assert_equal observer.public_id, group_observer.public_id
      @runtime.consume(update(17, "The shared topic fact after restart", user: 103, chat: -10, topic: 7))
      observed = await("the restarted adapter keeps the same observation history") do
        rows = observer.turns.list.items
        rows if rows.length == 2
      end
      assert_equal ["The shared topic fact before restart", "The shared topic fact after restart"],
        observed.map { |turn| turn.active_variant.content }
      assert observed.all? { |turn| turn.kind == "message" && turn.status == "completed" }
      assert observed.all? { |turn| turn.active_variant.run_public_id.nil? && turn.active_variant.model.nil? }

      assert_includes telegram_control(18, "/observe off", chat: -10, topic: 7), "Observe is off"
      assert_includes telegram_control(19, "/observe on", user: 102, chat: -10, topic: 7), "Only the bot owner"
      @runtime.consume(enabled)
      assert_includes telegram_control(20, "/observe status", user: 102, chat: -10, topic: 7), "Observe: off"
      @runtime.consume(update(21, "Do not record this message after observation stops", user: 102, chat: -10, topic: 7))
      assert_equal observed.map(&:public_id), observer.turns.list.items.map(&:public_id)

      @runtime.consume(update(22, "@rho_bot\n!mock reply=explicit-after-observation -- answer this direct request",
        user: 102, chat: -10, topic: 7, mention: true))
      chat = @workspace.conversation(current("-10:7", user: 102))
      reply = completed_reply(chat)
      material = request_text(reply)
      refute_includes material, "The shared topic fact before restart"
      refute_includes material, "The shared topic fact after restart"
      assert_equal "Mock: explicit-after-observation", group_bot_message("Mock: explicit-after-observation").fetch("text")
      assert_empty @logs
    end

    def test_group_participants_finish_independently_without_observation_filling_their_queues
      boot_runtime(allowed: [101, 102, 103])
      telegram_control(1, "/observe on", chat: -10, topic: 7)
      alice, running, = telegram_held_parent(2, user: 102, chat: -10, topic: 7)
      original_request = request_text(running)

      background = 40.times.map { |index| "Shared room fact #{index}: the release color is blue." }
      background.each.with_index(3) do |text, id|
        @runtime.consume(update(id, text, user: 103, chat: -10, topic: 7))
      end
      observer = group_observer
      refute_equal alice.public_id, observer.public_id
      observed = await("all background messages materialize without a model") do
        rows = observer.turns.list(limit: 100).items
        rows if rows.length == background.length
      end
      assert_equal background, observed.map { |turn| turn.active_variant.content }
      assert observed.all? { |turn| turn.kind == "message" && turn.status == "completed" }
      assert observed.all? { |turn| turn.active_variant.run_public_id.nil? && turn.active_variant.model.nil? }
      assert_empty observer.inputs.list.items
      assert_empty alice.inputs.list.items
      assert_equal "awaiting_input", telegram_question_task(running).status

      @runtime.consume(update(43, "@rho_bot\n!mock reply=bob-independent -- answer my separate request",
        user: 103, chat: -10, topic: 7, mention: true))
      bob = @workspace.conversation(current("-10:7", user: 103))
      refute_equal alice.public_id, bob.public_id
      refute_equal observer.public_id, bob.public_id
      answer = completed_reply(bob)
      assert_equal "Mock: bob-independent", answer.active_variant.content
      assert_includes request_text(answer), background.last
      refute_includes original_request, background.last
      assert_equal "awaiting_input", telegram_question_task(running).status
      assert_empty alice.inputs.list.items
      assert_empty bob.inputs.list.items
      assert_equal 1, group_input_events(alice).length
      assert_equal 1, group_input_events(bob).length
      assert_equal "Mock: bob-independent", group_bot_message("Mock: bob-independent").fetch("text")
      assert_empty @telegram.formal(102)
      assert_empty @telegram.formal(103)
      assert_empty @logs
    ensure
      stop_group_work(alice)
    end

    def test_group_controls_require_the_requester_or_owner_and_keep_the_exact_execution_after_restart
      boot_runtime(allowed: [101, 102, 103])
      alice, running, question_id, source = telegram_held_parent(1, user: 102, chat: -10, topic: 7)
      bob, bob_running, = telegram_held_parent(2, user: 103, chat: -10, topic: 7)
      before = group_input_events(alice).map(&:sequence)

      telegram_control(3, "/steer Bob must not change Alice's work", user: 103, chat: -10, topic: 7, reply_to: source)
      telegram_control(4, "/stop", user: 103, chat: -10, topic: 7, reply_to: source)
      assert_match(/requester or the bot owner/, telegram_control("foreign-answer", "/answer #{question_id} Continue",
        user: 103, chat: -10, topic: 7))
      assert_equal before, group_input_events(alice).map(&:sequence)
      assert_empty alice.inputs.list.items
      assert_empty bob.inputs.list.items
      assert_equal "awaiting_input", telegram_question_task(running).status
      assert_equal "awaiting_input", telegram_question_task(bob_running).status

      telegram_control(5, "/steer Alice's additional constraint", user: 102, chat: -10, topic: 7, reply_to: source)
      telegram_control(6, "/steer The owner's additional constraint", chat: -10, topic: 7, reply_to: source)
      steering = alice.inputs.list.items
      assert_equal ["Alice's additional constraint", "The owner's additional constraint"], steering.map(&:text)
      assert_equal %w[steer steer], steering.map(&:delivery_mode)
      assert_equal %w[steering steering], steering.map(&:state)
      assert_empty bob.inputs.list.items

      telegram_control(7, "/new", user: 102, chat: -10, topic: 7)
      selected = current("-10:7", user: 102)
      refute_equal alice.public_id, selected
      restart_group_runtime
      telegram_control(8, "/stop", user: 103, chat: -10, topic: 7, reply_to: source)
      assert_equal "awaiting_input", telegram_question_task(running).status
      telegram_control(9, "/stop", user: 102, chat: -10, topic: 7, reply_to: source)
      await_group_turn_status(alice, running, "canceled")
      assert_equal selected, current("-10:7", user: 102)
      assert_empty @workspace.conversation(selected).turns.list.items
      assert_equal "awaiting_input", telegram_question_task(bob_running).status

      replacement, replacement_turn, _, replacement_source = telegram_held_parent(10,
        user: 102, chat: -10, topic: 7)
      assert_equal selected, replacement.public_id
      telegram_control(11, "/steer This old execution must not become a new request",
        user: 102, chat: -10, topic: 7, reply_to: source)
      telegram_control(12, "/stop", chat: -10, topic: 7, reply_to: source)
      assert_empty replacement.inputs.list.items
      assert_equal 1, group_input_events(replacement).length
      assert_equal "awaiting_input", telegram_question_task(replacement_turn).status
      telegram_control(13, "/stop", chat: -10, topic: 7, reply_to: replacement_source)
      await_group_turn_status(replacement, replacement_turn, "canceled")
      assert_equal "awaiting_input", telegram_question_task(bob_running).status
      assert_empty @logs
    ensure
      stop_group_work(alice, bob, replacement)
    end

    def test_group_bot_replies_return_to_the_original_conversation_after_selection_and_restart
      boot_runtime(allowed: [101, 102, 103])
      @runtime.consume(update(1, "@rho_bot\n!mock reply=original-alice-answer -- Alice's first request",
        user: 102, chat: -10, topic: 7, mention: true))
      original = @workspace.conversation(current("-10:7", user: 102))
      first = completed_reply(original)
      bot_message = group_bot_message("Mock: original-alice-answer")
      tick
      telegram_control(2, "/new", user: 102, chat: -10, topic: 7)
      selected, running, question_id = telegram_held_parent(3, user: 102, chat: -10, topic: 7)
      restart_group_runtime

      incoming = update(4, "!mock reply=original-followup -- Continue the original conversation",
        user: 102, chat: -10, topic: 7)
      incoming.fetch("message")["reply_to_message"] = bot_message
      @bridge.lose_next_ack = true
      assert_raises(Rho::ConnectionError) { @runtime.consume(incoming) }
      boot_runtime(allowed: [101, 102, 103])
      @runtime.consume(incoming)
      @runtime.consume(incoming)
      replies = await("one follow-up in the original conversation") do
        rows = original.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
        rows if rows.length == 2
      end
      assert_equal first.public_id, replies.first.public_id
      assert_equal "Mock: original-followup", replies.last.active_variant.content
      assert_equal 2, group_input_events(original).length
      assert_equal selected.public_id, current("-10:7", user: 102)
      assert_equal "awaiting_input", telegram_question_task(running).status
      assert_equal "Mock: original-followup", group_bot_message("Mock: original-followup").fetch("text")

      foreign = update(5, "Do not append Bob's reply to Alice's task", user: 103, chat: -10, topic: 7)
      foreign.fetch("message")["reply_to_message"] = bot_message
      @runtime.consume(foreign)
      unknown = update(6, "Do not guess which Alice task owns this old message", user: 102, chat: -10, topic: 7)
      unknown.fetch("message")["reply_to_message"] = bot_message.merge("message_id" => 999_999_999)
      @runtime.consume(unknown)
      assert_equal 2, group_input_events(original).length
      assert_equal 1, group_input_events(selected).length
      assert_empty selected.inputs.list.items
      assert_equal "awaiting_input", telegram_question_task(running).status

      telegram_control("selected-parent-answer", "/answer #{question_id} Continue", user: 102, chat: -10, topic: 7)
      await_group_turn_status(selected, running, "completed")
      assert_equal "Mock: main-answer", group_bot_message("Mock: main-answer").fetch("text")
      assert_equal selected.public_id, current("-10:7", user: 102)
      assert_empty @logs
    ensure
      stop_group_work(selected)
    end

    def test_owner_access_and_ignore_commands_survive_restart_without_replaying_rejected_messages
      boot_runtime(allowed: [101])
      telegram_control(1, "/access users add 102")
      alice, alice_running, alice_question = telegram_held_parent(2, user: 102, chat: -10, topic: 7,
        reply: "alice-admitted")
      telegram_control(3, "/access users add 103", user: 102, chat: 102)
      telegram_control(4, "/ignore add 101", user: 102, chat: 102)
      telegram_control(5, "/access users add 103", chat: -10, topic: 7)
      count = @core.conversations.fetch("conversations").length
      @runtime.consume(update(6, "@rho_bot Bob has not been allowed", user: 103, chat: -10, topic: 7, mention: true))
      assert_equal count, @core.conversations.fetch("conversations").length
      telegram_control(7, "/access users add 103")
      bob, bob_running, bob_question = telegram_held_parent(8, user: 103, chat: -10, topic: 7,
        reply: "bob-admitted")
      telegram_control(9, "/observe on", chat: -10, topic: 7)
      @runtime.consume(update("context-before-ignore", "An admitted shared fact", user: 102, chat: -10, topic: 7))
      await("the admitted observation") { group_observer.turns.list.items.length == 1 }
      telegram_control(10, "/ignore add 102")
      telegram_control(11, "/access users remove 103")
      telegram_control(12, "/access users remove 101")
      telegram_control(13, "/ignore add 101")
      restart_group_runtime(allowed: [101])
      assert_includes telegram_control(14, "/ignore list"), "102"
      refute_includes telegram_control(15, "/access users list"), "103"

      ignored = update(16, "@rho_bot Do not admit this ignored request", user: 102, chat: -10, topic: 7, mention: true)
      removed = update(17, "@rho_bot Do not admit this removed user", user: 103, chat: -10, topic: 7, mention: true)
      @runtime.consume(ignored)
      @runtime.consume(removed)
      @runtime.consume(update(18, "Do not observe this ignored message", user: 102, chat: -10, topic: 7))
      assert_equal 1, group_input_events(alice).length
      assert_equal 1, group_input_events(bob).length
      assert_empty alice.inputs.list.items
      assert_empty bob.inputs.list.items
      assert_equal ["An admitted shared fact"], group_observer.turns.list.items.map { |turn| turn.active_variant.content }
      # Already accepted work stays deliverable after the sender is removed.
      telegram_control("ignored-alice-answer", "/answer #{alice_question} Continue", chat: -10, topic: 7)
      telegram_control("removed-bob-answer", "/answer #{bob_question} Continue", chat: -10, topic: 7)
      assert_equal "Mock: alice-admitted", group_bot_message("Mock: alice-admitted").fetch("text")
      assert_equal "Mock: bob-admitted", group_bot_message("Mock: bob-admitted").fetch("text")

      telegram_control(19, "/ignore remove 102")
      telegram_control(20, "/access users add 103")
      @runtime.consume(update(10, "/ignore add 102"))
      @runtime.consume(update(11, "/access users remove 103"))
      @runtime.consume(ignored)
      @runtime.consume(removed)
      stale = update(21, "@rho_bot This old message must not start work", user: 102, chat: -10, topic: 7, mention: true)
      stale.fetch("message")["date"] = Time.now.to_i - 601
      @runtime.consume(stale)
      assert_equal 1, group_input_events(alice).length
      assert_equal 1, group_input_events(bob).length
      @runtime.consume(update(22, "@rho_bot\n!mock reply=alice-restored -- A fresh allowed message",
        user: 102, chat: -10, topic: 7, mention: true))
      assert_equal "Mock: alice-restored", group_bot_message("Mock: alice-restored").fetch("text")
      assert_equal 2, group_input_events(alice).length
      @runtime.consume(update(23, "@rho_bot\n!mock reply=bob-restored -- A fresh request after being allowed again",
        user: 103, chat: -10, topic: 7, mention: true))
      assert_equal "Mock: bob-restored", group_bot_message("Mock: bob-restored").fetch("text")
      assert_equal 2, group_input_events(bob).length
      assert_empty @logs
    ensure
      stop_group_work(alice, bob)
    end

    module Helpers
      private

        def group_observer
          @workspace.conversation(@state.read.fetch("rooms").fetch("-10:7").fetch("conversation_id"))
        end

        def group_input_events(conversation)
          conversation.events(limit: 100).select { |event| event.type == "input_accepted" }
        end

        def group_bot_message(text)
          id, params = await("the group message #{text}") do
            tick
            @telegram.messages.find do |_message_id, entry|
              entry.values_at(:chat_id, :message_thread_id, :text) == ["-10", 7, text]
            end
          end
          { "message_id" => id, "from" => @bot.merge("is_bot" => true), "text" => params.fetch(:text) }
        end

        def restart_group_runtime(allowed: [101, 102, 103])
          @runtime.close
          @daemon.stop
          @daemon.start
          @daemon.await("the restarted daemon adopts its saved workspace") do
            @daemon.status.dig("workspace", "state") == "adopted"
          end
          connect_bridge(@workspace.public_id)
          boot_runtime(allowed: allowed)
        end

        def stop_group_work(*conversations)
          conversations.compact.each do |conversation|
            @core.stop(conversation.public_id)
          rescue Rho::Core::Refused => error
            raise unless error.code == "not_running"
          end
        end

        def await_group_turn_status(conversation, turn, status)
          await("the original group turn becomes #{status}") do
            tick
            conversation.turns.list.items.find { |row| row.public_id == turn.public_id }&.status == status
          end
        end
    end
  end
end
