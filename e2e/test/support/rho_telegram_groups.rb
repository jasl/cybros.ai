module E2E
  # A Bot has one shared current conversation. Sender attribution and exact task
  # control remain separate even when the owner starts a new shared conversation.
  module RhoTelegramGroups
    def test_group_observation_settings_keep_owner_authority_and_exact_room_scope_after_restart
      boot_runtime(allowed: [101, 102, 103])
      assert_nil @core.bot_detail(agent_public_id: bot_id_for("-10:7"))["current"]
      enabled = update(2, "/observe on", chat: -10, topic: 7)
      receive(enabled)
      assert_includes telegram_control(3, "/observe status", user: 102, chat: -10, topic: 7), "Observe: on"
      assert_includes telegram_control(4, "/observe", user: 103, chat: -10, topic: 7), "Observe: on"
      assert_includes telegram_control(5, "/observe off", user: 102, chat: -10, topic: 7), "Only the bot owner"
      assert_includes telegram_control(6, "/observe status", user: 102, chat: -10, topic: 8), "Observe: off"
      assert_nil @core.bot_detail(agent_public_id: bot_id_for("-10:7"))["current"], "settings do not create a conversation"

      receive(update(7, "The shared topic fact before restart", user: 102, chat: -10, topic: 7))
      receive(update(8, "A different topic stays unobserved", user: 102, chat: -10, topic: 8))
      receive(update(9, "An unbound group stays unobserved", user: 102, chat: -20, topic: 7))
      receive(update(10, "The unbound non-topic room stays unobserved", user: 102, chat: -10))
      observer = group_observer
      observed = await("the topic's observation materializes without execution") do
        rows = observer.turns.list.items
        rows if rows.length == 1
      end
      assert_equal "The shared topic fact before restart", observed.first.active_variant.content
      assert_equal "message", observed.first.kind
      assert_equal "completed", observed.first.status
      assert_nil observed.first.active_variant.run_public_id
      assert_nil observed.first.active_variant.model
      assert_empty observer.inputs.list.items
      assert_nil @core.bot_detail(agent_public_id: bot_id_for("-10:8"))["current"]

      restart_group_runtime
      assert_includes telegram_control(11, "/observe status", user: 103, chat: -10, topic: 7), "Observe: on"
      assert_equal observer.public_id, group_observer.public_id
      receive(update(12, "The shared topic fact after restart", user: 103, chat: -10, topic: 7))
      observed = await("the restarted adapter keeps the same observation history") do
        rows = observer.turns.list.items
        rows if rows.length == 2
      end
      assert_equal ["The shared topic fact before restart", "The shared topic fact after restart"],
        observed.map { |turn| turn.active_variant.content }
      assert observed.all? { |turn| turn.kind == "message" && turn.status == "completed" }
      assert observed.all? { |turn| turn.active_variant.run_public_id.nil? && turn.active_variant.model.nil? }
      refute_equal observed.first.speaker.speaker_public_id, observed.last.speaker.speaker_public_id

      assert_includes telegram_control(13, "/observe off", chat: -10, topic: 7), "Observe is off"
      assert_includes telegram_control(14, "/observe on", user: 102, chat: -10, topic: 7), "Only the bot owner"
      receive(enabled)
      assert_includes telegram_control(15, "/observe status", user: 102, chat: -10, topic: 7), "Observe: off"
      receive(update(16, "Do not record this message after observation stops", user: 102, chat: -10, topic: 7))
      assert_equal observed.map(&:public_id), observer.turns.list.items.map(&:public_id)

      receive(update(17, "@rho_bot\n!mock reply=explicit-after-observation -- answer this direct request",
        user: 102, chat: -10, topic: 7, mention: true))
      assert_equal observer.public_id, current("-10:7", user: 102)
      reply = completed_reply(observer)
      material = request_text(reply)
      assert_includes material, "The shared topic fact before restart"
      assert_includes material, "The shared topic fact after restart"
      refute_includes material, "Do not record this message after observation stops"
      assert_equal "Mock: explicit-after-observation", group_bot_message("Mock: explicit-after-observation").fetch("text")
      assert_empty @logs
    end

    def test_group_participants_share_the_queue_while_observation_never_starts_model_work
      boot_runtime(allowed: [101, 102, 103])
      telegram_control(1, "/observe on", chat: -10, topic: 7)
      chat, running, question_id = telegram_held_parent(2, user: 102, chat: -10, topic: 7)
      original_request = request_text(running)
      background = 6.times.map { |index| "Shared room fact #{index}: the release color is blue." }
      background.each.with_index(3) { |text, id| receive(update(id, text, user: 103, chat: -10, topic: 7)) }
      assert_equal chat.public_id, group_observer.public_id
      assert_equal "awaiting_input", telegram_question_task(running).status
      assert_equal background, chat.inputs.list.items.map(&:text)
      assert_equal ["message"], chat.inputs.list.items.map(&:kind).uniq

      receive(update(10, "@rho_bot\n!mock reply=bob-next -- answer my queued request",
        user: 103, chat: -10, topic: 7, mention: true))
      assert_equal chat.public_id, current("-10:7", user: 103)
      assert_equal background.length + 1, chat.inputs.list.items.length
      assert_equal 1, chat.turns.list.items.count { |turn| turn.kind == "direct_reply" }
      assert_equal "awaiting_input", telegram_question_task(running).status
      telegram_control(11, "/answer #{question_id} Continue", user: 102, chat: -10, topic: 7)
      replies = await("the shared queue drains after the original answer") do
        tick
        rows = chat.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
        rows if rows.length == 2
      end
      assert_equal ["Mock: main-answer", "Mock: bob-next"], replies.map { |turn| turn.active_variant.content }
      observed = chat.turns.list.items.select { |turn| turn.kind == "message" }
      assert_equal background, observed.map { |turn| turn.active_variant.content }
      assert observed.all? { |turn| turn.active_variant.run_public_id.nil? && turn.active_variant.model.nil? }
      assert_includes request_text(replies.last), background.last
      refute_includes original_request, background.last
      assert_empty chat.inputs.list.items
      assert_equal "Mock: bob-next", group_bot_message("Mock: bob-next").fetch("text")
      assert_empty @telegram.formal(102)
      assert_empty @telegram.formal(103)
      assert_empty @logs
    ensure
      stop_group_work(chat)
    end

    def test_group_controls_require_the_requester_or_owner_and_keep_the_exact_execution_after_restart
      boot_runtime(allowed: [101, 102, 103])
      alice, running, question_id, source = telegram_held_parent(1, user: 102, chat: -10, topic: 7)
      telegram_control("owner-new-for-bob", "/new", chat: -10, topic: 7)
      bob, bob_running, = telegram_held_parent(2, user: 103, chat: -10, topic: 7)
      refute_equal alice.public_id, bob.public_id
      assert @core.conversation(alice.public_id).fetch("archived_at")
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
      assert_includes telegram_control("member-new-refused", "/new", user: 102, chat: -10, topic: 7), "Only the bot owner"
      assert_equal bob.public_id, current("-10:7")
      telegram_control(7, "/new", chat: -10, topic: 7)
      selected = current("-10:7")
      restart_group_runtime
      telegram_control(8, "/stop", user: 103, chat: -10, topic: 7, reply_to: source)
      assert_equal "awaiting_input", telegram_question_task(running).status
      telegram_control(9, "/stop", user: 102, chat: -10, topic: 7, reply_to: source)
      await_group_turn_status(alice, running, "canceled")
      assert_equal selected, current("-10:7", user: 102)
      assert_empty @workspace.conversation(selected).turns.list.items
      assert_equal "awaiting_input", telegram_question_task(bob_running).status

      replacement, replacement_turn, _, replacement_source = telegram_held_parent(10, user: 102, chat: -10, topic: 7)
      assert_equal selected, replacement.public_id
      telegram_control(11, "/steer This old execution must not become a new request", user: 102, chat: -10, topic: 7, reply_to: source)
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

    def test_group_bot_replies_keep_the_original_history_and_require_owner_resume_after_archive
      boot_runtime(allowed: [101, 102, 103])
      receive(update(1, "@rho_bot\n!mock reply=original-alice-answer -- Alice's first request",
        user: 102, chat: -10, topic: 7, mention: true))
      original = @workspace.conversation(current("-10:7"))
      first = completed_reply(original)
      bot_message = group_bot_message("Mock: original-alice-answer")
      telegram_control(2, "/new", chat: -10, topic: 7)
      selected = current("-10:7")
      restart_group_runtime
      incoming = update(3, "!mock reply=archived-followup -- Do not append to an archived conversation",
        user: 102, chat: -10, topic: 7)
      incoming.fetch("message")["reply_to_message"] = bot_message
      receive(incoming)
      assert_equal 1, group_input_events(original).length
      assert_empty @workspace.conversation(selected).turns.list.items
      assert_equal selected, current("-10:7")

      telegram_control(4, "/sessions", chat: -10, topic: 7)
      telegram_control(5, "/resume #{original.public_id}", chat: -10, topic: 7)
      assert_equal original.public_id, current("-10:7")
      incoming = update(6, "!mock reply=original-followup -- Continue the resumed original conversation",
        user: 102, chat: -10, topic: 7)
      incoming.fetch("message")["reply_to_message"] = bot_message
      @bridge.lose_next_ack = true
      receive(incoming)
      assert pending_input(incoming).fetch("submission")
      assert_equal "Rho::ConnectionError", @logs.pop.last.fetch(:reason)
      boot_runtime(allowed: [101, 102, 103])
      receive(incoming)
      receive(incoming)
      replies = await("one follow-up in the resumed original conversation") do
        tick
        rows = original.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
        rows if rows.length == 2
      end
      assert_equal first.public_id, replies.first.public_id
      assert_equal "Mock: original-followup", replies.last.active_variant.content
      assert_equal 2, group_input_events(original).length
      assert_equal "Mock: original-followup", group_bot_message("Mock: original-followup").fetch("text")
      foreign = update(7, "Do not append Bob's reply to Alice's task", user: 103, chat: -10, topic: 7)
      foreign.fetch("message")["reply_to_message"] = bot_message
      receive(foreign)
      unknown = update(8, "Do not guess which task owns this old message", user: 102, chat: -10, topic: 7)
      unknown.fetch("message")["reply_to_message"] = bot_message.merge("message_id" => 999_999_999)
      receive(unknown)
      assert_equal 2, group_input_events(original).length
      assert_empty original.inputs.list.items
      assert_empty @logs
    end

    def test_owner_access_and_ignore_commands_survive_restart_without_replaying_rejected_messages
      boot_runtime(allowed: [101])
      telegram_control(1, "/access users add 102", chat: -10, topic: 7)
      alice, _alice_running, alice_question = telegram_held_parent(2, user: 102, chat: -10, topic: 7, reply: "alice-admitted")
      assert_includes telegram_control(3, "/access users add 103", user: 102, chat: -10, topic: 7), "Only the bot owner"
      telegram_control(4, "/new", chat: -10, topic: 7)
      telegram_control(5, "/access users add 103", chat: -10, topic: 7)
      bob, _bob_running, bob_question = telegram_held_parent(6, user: 103, chat: -10, topic: 7, reply: "bob-admitted")
      assert_equal 1, group_input_events(alice).length
      assert_equal 1, group_input_events(bob).length
      ignored_command = update(7, "/ignore add 102", chat: -10, topic: 7)
      removed_command = update(8, "/access users remove 103", chat: -10, topic: 7)
      receive(ignored_command)
      receive(removed_command)
      assert_includes telegram_control(9, "/access users remove 101", chat: -10, topic: 7), "always allowed"
      assert_includes telegram_control(10, "/ignore add 101", chat: -10, topic: 7), "always allowed"
      restart_group_runtime(allowed: [101])
      assert_includes telegram_control(11, "/ignore list", chat: -10, topic: 7), "102"
      refute_includes telegram_control(12, "/access users list", chat: -10, topic: 7), "103"
      ignored = update(13, "@rho_bot Do not admit this ignored request", user: 102, chat: -10, topic: 7, mention: true)
      removed = update(14, "@rho_bot Do not admit this removed request", user: 103, chat: -10, topic: 7, mention: true)
      receive(ignored)
      receive(removed)
      assert_empty alice.inputs.list.items
      assert_empty bob.inputs.list.items
      # Already accepted work remains answerable and deliverable after removal.
      telegram_control(15, "/answer #{alice_question} Continue", chat: -10, topic: 7)
      telegram_control(16, "/answer #{bob_question} Continue", chat: -10, topic: 7)
      assert_equal "Mock: alice-admitted", group_bot_message("Mock: alice-admitted").fetch("text")
      assert_equal "Mock: bob-admitted", group_bot_message("Mock: bob-admitted").fetch("text")
      telegram_control(17, "/ignore remove 102", chat: -10, topic: 7)
      telegram_control(18, "/access users add 103", chat: -10, topic: 7)
      receive(ignored_command)
      receive(removed_command)
      receive(ignored)
      receive(removed)
      stale = update(19, "@rho_bot This old message must not start work", user: 102, chat: -10, topic: 7, mention: true)
      stale.fetch("message")["date"] = Time.now.to_i - 601
      receive(stale)
      assert_equal 1, group_input_events(alice).length
      assert_equal 1, group_input_events(bob).length
      receive(update(20, "@rho_bot\n!mock reply=alice-restored -- A fresh allowed message", user: 102, chat: -10, topic: 7, mention: true))
      assert_equal "Mock: alice-restored", group_bot_message("Mock: alice-restored").fetch("text")
      receive(update(21, "@rho_bot\n!mock reply=bob-restored -- A fresh request after being allowed again", user: 103, chat: -10, topic: 7, mention: true))
      assert_equal "Mock: bob-restored", group_bot_message("Mock: bob-restored").fetch("text")
      assert_equal 3, group_input_events(bob).length
      assert_equal bob.public_id, current("-10:7")
      assert_empty @logs
    ensure
      stop_group_work(alice, bob)
    end

    module Helpers
      private

        def group_observer
          @workspace.conversation(current("-10:7"))
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
          @bot_runtimes.each_value(&:close)
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
