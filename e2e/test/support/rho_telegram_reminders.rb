module E2E
  module RhoTelegramReminders
    def test_one_time_telegram_reminder_waits_then_reschedules_after_restart_and_cancel_stays_absent
      boot_runtime(allowed: [101])
      first = telegram_control("reminder-first", "/remind in 1h Submit the report.\n!mock reply=telegram-reminder -- reminder")
      first_id = telegram_task_id(first)
      chat = @workspace.conversation(current("101:0"))
      first_input = chat.inputs.list.items.find { |row| row.public_id == first_id }
      refute_nil first_input
      assert_equal "pending", first_input.state
      assert_equal "queue", first_input.delivery_mode
      assert_operator Time.iso8601(first_input.deliver_at), :>, Time.now + 3_000
      assert_includes first, first_input.deliver_at
      assert_empty chat.turns.list.items, "a future reminder does not start a reply turn"

      canceled = telegram_control("reminder-canceled", "/remind in 1h Canceled reminder.\n!mock reply=never-remind -- never")
      canceled_id = telegram_task_id(canceled)
      listing = telegram_control("reminder-list", "/queue")
      [first_id, canceled_id].each { |id| assert_includes listing, id }
      assert_includes telegram_control("reminder-cancel", "/queue cancel 2"), "canceled"
      assert_equal [first_id], chat.inputs.list.items.map(&:public_id)

      restart_group_runtime(allowed: [101])
      @state = telegram_state
      boot_runtime(allowed: [101])
      assert_equal chat.public_id, current("101:0")
      assert_equal [first_id], chat.inputs.list.items.map(&:public_id)
      assert_empty chat.turns.list.items, "restart leaves the reminder pending before its due time"
      refute_path_exists File.join(@home.root, "telegram", "state.json")

      now = telegram_control("reminder-now", "/queue reschedule 1 now")
      assert_includes now, "rescheduled for"
      reply = completed_reply(chat)
      assert_equal "Mock: telegram-reminder", reply.active_variant.content
      assert_empty chat.inputs.list.items
      materialized = chat.events(limit: 100).select { |event| event.type == "input_materialized" }
      assert_equal [first_id], materialized.map { |event| event.payload.fetch("input_public_id") }
      await("the rescheduled reminder is delivered to the original private chat") do
        tick
        @telegram.formal(101).any? { |_method, params| params[:text] == "Mock: telegram-reminder" }
      end
      tick
      assert_equal ["Mock: telegram-reminder"], @telegram.formal(101).map { |_method, params| params.fetch(:text) }
      assert_empty @logs
    ensure
      stop_group_work(chat)
    end
  end
end
