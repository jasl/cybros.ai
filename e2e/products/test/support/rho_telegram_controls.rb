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

      receive(update(2, "!mock reply=queued-answer -- a separate waiting request"))
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
          receive(incoming)
          receipt = @state.read.fetch("deliveries").values.find { |entry| entry["update_id"] == incoming.fetch("update_id") }
          expected = receipt.fetch("text")
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
