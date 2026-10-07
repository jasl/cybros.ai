module E2E
  module RhoTelegramDestinations
    def test_telegram_result_destination_survives_restart_without_moving_execution_memory_or_questions
      boot_runtime(allowed: [101, 102])
      telegram_control("destination-room", "/new", chat: -10, topic: 7)
      destination_id = current("-10:7")
      source, running, question_id = telegram_held_parent("destination-source", reply: "destination-report")
      source_id = source.public_id
      source_loop = running.active_variant.run_public_id
      materialized = source.events(limit: 100).find do |event|
        event.type == "input_materialized" && event.payload["turn_public_id"] == running.public_id
      end
      task_id = materialized.payload.fetch("input_public_id")
      note = @core.memory_write(source_id, path: "conversation/source.md", content: "The source task keeps this note.",
        expected_public_id: nil, expected_lock_version: nil)
      before = @core.conversation(source_id)
      listing = telegram_control("destination-list", "/destinations")
      assert_includes listing, "-10:7"
      redirected = telegram_control("destination-select", "/deliver #{task_id} -10:7")
      assert_includes redirected, "questions and approvals stay in the source"
      assert_equal source_id, current("101:0")
      assert_equal destination_id, current("-10:7")
      assert_includes telegram_control("destination-question-refusal", "/answer #{question_id} Continue", chat: -10, topic: 7),
        "no longer available in this chat"
      assert_equal "awaiting_input", telegram_question_task(running).status
      assert_includes telegram_control("destination-member-refusal", "/stop #{task_id}", user: 102, chat: -10, topic: 7),
        "not available in this chat/topic"
      assert_includes telegram_control("destination-topic-refusal", "/stop #{task_id}", chat: -10, topic: 8),
        "not available in this chat/topic"

      restart_group_runtime(allowed: [101, 102])
      @state = telegram_state
      boot_runtime(allowed: [101, 102])
      status = telegram_control("destination-status", "/status #{task_id}", chat: -10, topic: 7)
      assert_includes status, source_loop
      assert_includes telegram_control("destination-steer", "/steer #{task_id} Keep this same report and source context.", chat: -10, topic: 7),
        "instruction is accepted"
      assert_equal "awaiting_input", telegram_question_task(running).status
      question_message = await("the question is still delivered at the source") do
        tick
        @telegram.messages.values.find { |row| row.fetch(:text, "").start_with?("Question (#{question_id})") }
      end
      assert_equal "101", question_message.fetch(:chat_id)
      assert_nil question_message[:message_thread_id]
      telegram_control("destination-answer", "/answer #{question_id} Continue")
      reply = completed_reply(source)
      assert_equal running.public_id, reply.public_id
      assert_equal source_loop, reply.active_variant.run_public_id
      assert_equal "Mock: destination-report", reply.active_variant.content
      delivered_id, delivered = await("the final result reaches its saved destination after restart") do
        tick
        @telegram.messages.find do |_id, row|
          row.values_at(:chat_id, :message_thread_id) == ["-10", 7] && row.fetch(:text, "").include?("Mock: destination-report")
        end
      end
      refute delivered.key?(:reply_parameters)
      assert_includes delivered.fetch(:text), task_id
      assert @telegram.formal(101).none? { |_method, row| row.fetch(:text, "").include?("Mock: destination-report") }
      assert_equal source_id, current("101:0")
      assert_equal destination_id, current("-10:7")
      assert_equal before.values_at("public_id", "workspace_public_id", "answering_user_public_id"),
        @core.conversation(source_id).values_at("public_id", "workspace_public_id", "answering_user_public_id")
      assert_equal note.fetch("public_id"), @core.memory_read(source_id, path: "conversation/source.md").fetch("public_id")
      assert_equal "The source task keeps this note.", @core.memory_read(source_id, path: "conversation/source.md").fetch("content")
      assert_empty @workspace.conversation(destination_id).turns.list.items

      bot_message = { "message_id" => delivered_id, "from" => @bot.merge("is_bot" => true), "text" => delivered.fetch(:text) }
      inputs_before = source.events(limit: 100).count { |event| event.type == "input_accepted" }
      refusal = telegram_control("destination-ordinary-reply", "Read the source's other private notes", chat: -10, topic: 7, reply_to: bot_message)
      assert_includes refusal, "This is a delivered result"
      assert_equal inputs_before, source.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_includes telegram_control("destination-completed-copy", "/deliver #{task_id} -10:7"), "latest completed result"
      tick
      copies = @telegram.messages.values.count do |row|
        row.values_at(:chat_id, :message_thread_id) == ["-10", 7] && row.fetch(:text, "").include?("Mock: destination-report")
      end
      assert_equal 1, copies
      assert_includes telegram_control("destination-completed-stop", "/stop #{task_id}", chat: -10, topic: 7), "Stop requested"
      assert_equal [source_loop], @bridge.stops
      refute_path_exists File.join(@home.root, "telegram", "state.json")
      assert_empty @logs
    ensure
      stop_group_work(source)
    end
  end
end
