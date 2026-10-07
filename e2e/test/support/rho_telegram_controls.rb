module E2E
  # Busy work is held by a real ask. Queue edits, routing and recovery cross
  # the public daemon and Nexus doors; only Telegram and the provider are fake.
  module RhoTelegramControls
    def test_telegram_task_ids_keep_their_original_work_after_new_and_restart
      boot_runtime(allowed: [101])
      original, running, = telegram_held_parent(1)
      task_id = telegram_task_id(telegram_control("original-status", "/status"))
      accepted = original.events(limit: 100).find { |event| event.type == "input_accepted" }
      assert_equal accepted.payload.fetch("input_public_id"), task_id
      loop_id = running.active_variant.run_public_id

      @runtime.consume(update(2, "!mock reply=queued-answer -- a separate waiting request"))
      queued_id = original.inputs.list.items.fetch(0).public_id
      refute_equal task_id, queued_id
      assert_equal [queued_id], original.inputs.list.items.map(&:public_id)
      assert_includes telegram_control(3, "/queue"), queued_id
      assert_includes telegram_control(4, "/status #{queued_id}"), "Input: pending"
      assert_includes telegram_control(5, "/stop #{queued_id}"), "Stop requested"
      assert_empty original.inputs.list.items
      assert_equal "awaiting_input", telegram_question_task(running).status

      telegram_control(6, "/new")
      selected, selected_turn, question_id, selected_source = telegram_held_parent(7)
      refute_equal original.public_id, selected.public_id
      restart_group_runtime(allowed: [101])

      status = telegram_control(8, "/status #{task_id}", reply_to: selected_source)
      assert_includes status, "Task: #{task_id}"
      assert_includes status, "Conversation: #{original.public_id}"
      assert_includes status, "Root execution: running (#{loop_id})"
      refute_includes status, selected_turn.active_variant.run_public_id
      correction = "Keep the original task's goal."
      assert_includes telegram_control(9, "/steer #{task_id} #{correction}", reply_to: selected_source), "instruction is accepted"
      steering = original.inputs.list.items
      assert_equal [correction], steering.map(&:text)
      assert_equal ["steer"], steering.map(&:delivery_mode)
      assert_equal [loop_id], steering.map(&:expected_steering_run_public_id)
      assert_empty selected.inputs.list.items
      assert_includes telegram_control(10, "/status #{task_id}"), "Root execution: running (#{loop_id})"
      assert_includes telegram_control(11, "/status"), "Conversation: #{selected.public_id}"

      assert_includes telegram_control(12, "/stop #{task_id}", reply_to: selected_source), "Stop requested"
      await_group_turn_status(original, running, "canceled")
      assert_equal "awaiting_input", telegram_question_task(selected_turn).status
      assert_includes telegram_control(13, "/status"), "Conversation: #{selected.public_id}"
      telegram_control(14, "/answer #{question_id} Continue")
      await_group_turn_status(selected, selected_turn, "completed")
      assert_empty @logs
    ensure
      stop_group_work(original, selected)
    end

    def test_telegram_queue_edits_and_session_resume_survive_daemon_restart
      boot_runtime(allowed: [101])
      telegram_control(0, "/model #{self.class::MODEL}")
      chat, running, question_id = telegram_held_parent(1)
      queued_text = "!mock reply=original-queued-answer -- revise this queued request"
      canceled_text = "!mock reply=canceled-answer -- cancel this queued request"
      edited_text = "!mock reply=edited-queued-answer -- the revised queued request"
      @runtime.consume(update(2, queued_text))
      @runtime.consume(update(3, canceled_text))
      queued = chat.inputs.list.items
      assert_equal [queued_text, canceled_text], queued.map(&:text)
      assert_equal %w[pending pending], queued.map(&:state)

      status = telegram_control(4, "/status")
      assert_includes status, chat.public_id
      assert_includes status, self.class::MODEL
      assert_match(/Queued:\s*2/i, status)
      assert_match(/Current action:\s*Waiting for an answer/i, status)
      assert_match(/Pending requests:\s*1/i, status)
      listing = telegram_control(5, "/queue")
      assert_includes listing, "revise this queued request"
      assert_includes listing, "cancel this queued request"

      telegram_control(6, "/queue edit 1 #{edited_text}")
      edited = chat.inputs.list.items
      assert_equal queued.map(&:public_id), edited.map(&:public_id)
      assert_equal [edited_text, canceled_text], edited.map(&:text)
      telegram_control(7, "/queue cancel 2")
      assert_equal [queued.first.public_id], chat.inputs.list.items.map(&:public_id)
      assert_equal "awaiting_input", telegram_question_task(running).status
      assert_match(/Queued:\s*1/i, telegram_control(8, "/status"))

      telegram_control(9, "/new")
      other_id = current("101:0")
      refute_equal chat.public_id, other_id
      listing = telegram_control(10, "/sessions")
      assert_includes listing, chat.public_id
      assert_includes listing, other_id
      telegram_control(11, "/resume #{chat.public_id}")
      assert_equal chat.public_id, current("101:0")
      bindings = @core.conversation(chat.public_id).fetch("ingresses")
      assert_equal ["101"], bindings.map { |binding| binding.fetch("chat_id") }

      @runtime.close
      @daemon.stop
      @daemon.start
      connect_bridge(@workspace.public_id)
      boot_runtime(allowed: [101])
      assert_equal chat.public_id, current("101:0")
      assert_equal [queued.first.public_id], chat.inputs.list.items.map(&:public_id)
      assert_equal [edited_text], chat.inputs.list.items.map(&:text)
      assert_includes telegram_control(12, "/status"), chat.public_id
      telegram_control(13, "/answer #{question_id} Continue")

      replies = await("the held reply and the edited queued request after restart") do
        tick
        rows = chat.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
        rows if rows.length == 2
      end
      assert_equal running.public_id, replies.first.public_id
      assert_equal ["Mock: main-answer", "Mock: edited-queued-answer"], replies.map { |turn| turn.active_variant.content }
      assert_empty chat.inputs.list.items
      assert_empty @workspace.conversation(other_id).turns.list.items
      events = chat.events(limit: 100).items
      assert_equal 3, events.count { |event| event.type == "input_accepted" }, "slash controls must not become model input"
      materialized = events.select { |event| event.type == "input_materialized" }.map { |event| event.payload["input_public_id"] }
      assert_includes materialized, queued.first.public_id
      refute_includes materialized, queued.last.public_id
      await("only the held and edited answers reach the original chat") { tick; @telegram.formal(101).length == 2 }
      assert_equal ["Mock: main-answer", "Mock: edited-queued-answer"], @telegram.formal(101).map { |_method, params| params.fetch(:text) }
      assert @telegram.formal(101).all? { |_method, params| params[:message_thread_id].nil? }
      assert_empty @logs
    end

    def test_telegram_sessions_and_resume_stay_in_the_source_chat_and_topic
      boot_runtime(allowed: [101, 102])
      original, running, question_id = telegram_held_parent(1)
      assert_includes telegram_control(2, "/side Explain the current work"), "not available in Telegram"
      telegram_control(3, "/new")
      selected_id = current("101:0")
      telegram_control(4, "/new", user: 102, chat: 102)
      other_private_id = current("102:0")
      telegram_control(5, "/new", chat: -10, topic: 7)
      topic_seven_id = current("-10:7")
      telegram_control(6, "/new", chat: -10, topic: 8)
      topic_eight_id = current("-10:8")

      listing = telegram_control(7, "/sessions 1")
      assert_includes listing, original.public_id
      assert_includes listing, selected_id
      foreign_ids = [other_private_id, topic_seven_id, topic_eight_id]
      foreign_ids.each { |id| refute_includes listing, id }
      foreign_ids.each.with_index(8) do |id, update_id|
        telegram_control(update_id, "/resume #{id}")
        assert_equal selected_id, current("101:0"), "a foreign session must not replace the private session"
      end
      assert_includes telegram_control(12, "/status"), selected_id

      listing = telegram_control(13, "/sessions", chat: -10, topic: 7)
      assert_includes listing, topic_seven_id
      [original.public_id, selected_id, other_private_id, topic_eight_id].each do |id|
        refute_includes listing, id
      end
      telegram_control(14, "/resume #{topic_eight_id}", chat: -10, topic: 7)
      telegram_control(15, "/resume #{original.public_id}", chat: -10, topic: 7)
      assert_equal topic_seven_id, current("-10:7")
      assert_equal topic_eight_id, current("-10:8")
      assert_equal "awaiting_input", telegram_question_task(running).status

      # A request belongs to its originating route even while another session is
      # selected. Its old question remains answerable there after the switch.
      telegram_control(16, "/answer #{question_id} Continue")
      await("the original answer returns after selecting another session") do
        tick
        @telegram.formal(101).any? { |_method, params| params[:text] == "Mock: main-answer" }
      end
      assert_equal selected_id, current("101:0")
      assert_empty @telegram.formal(102)
      assert_empty @telegram.formal(-10)
      assert_equal ["Mock: main-answer"],
        @telegram.formal(101).map { |_method, params| params.fetch(:text) }
      assert @telegram.formal(101).all? { |_method, params| params[:message_thread_id].nil? }
      [selected_id, other_private_id, topic_seven_id, topic_eight_id].each do |id|
        assert_empty @workspace.conversation(id).turns.list.items, "session controls must not enqueue model requests"
      end
      assert_equal 1, original.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_empty @logs
    end

    module Helpers
      private

        def telegram_task_id(reply)
          match = reply.match(/(?:\nTask: |\nRecent task IDs:\n)([0-9a-f-]{36})(?:\n|\z)/)
          refute_nil match, "the delivered Telegram control reply must contain a full task ID"
          match[1]
        end

        def telegram_control(id, text, user: 101, chat: 101, topic: nil, reply_to: nil)
          before = @telegram.calls.length
          incoming = update(id, text, user: user, chat: chat, topic: topic)
          incoming.fetch("message")["reply_to_message"] = reply_to if reply_to
          @runtime.consume(incoming)
          expected = @state.read.fetch("deliveries").fetch("control:#{incoming.fetch("update_id")}").fetch("text")
          delivered = await("the Telegram control reply for update #{id}") do
            tick
            @telegram.calls.drop(before).find do |method, params|
              method == "sendMessage" && params[:text] == expected &&
                params.values_at(:chat_id, :message_thread_id) == [chat.to_s, topic]
            end
          end
          # Receipts locate the exact control reply; assertions use what the
          # recording Bot API received, after the delivery worker sent it.
          delivered.last.fetch(:text)
        end
    end
  end
end
