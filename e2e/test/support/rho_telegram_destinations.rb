module E2E
  module RhoTelegramDestinations
    def test_result_destinations_use_only_this_bots_recorded_targets_and_preserve_original_work
      boot_runtime(allowed: [101, 102])
      telegram_control("destination-room", "/new", chat: -10, topic: 7)
      foreign_id = current("-10:7")
      source, running, question_id = telegram_held_parent("destination-source", reply: "destination-report")
      source_id = source.public_id
      source_loop = running.active_variant.run_public_id
      materialized = source.events(limit: 100).find do |event|
        event.type == "input_materialized" && event.payload["turn_public_id"] == running.public_id
      end
      task_id = materialized.payload.fetch("input_public_id")
      note = @core.memory_write(source_id, path: "conversation/source.md", content: "The source task keeps this note.",
        expected_collection_public_id: @core.memory_target(source_id, path: "conversation/source.md", workspace_public_id: @workspace.public_id).fetch("collection_public_id"),
        expected_public_id: nil, expected_lock_version: nil, workspace_public_id: @workspace.public_id)
      before = @core.conversation(source_id, workspace_public_id: @workspace.public_id)
      destination = telegram_route_key("101:0")
      foreign_destination = telegram_route_key("-10:7")
      listing = telegram_control("destination-list", "/destinations")
      assert_includes listing, destination
      refute_includes listing, foreign_destination, "another Bot's fixed target is not part of this Bot's routes"
      assert_includes telegram_control("destination-foreign", "/deliver #{task_id} #{foreign_destination}"), "not available"
      redirected = telegram_control("destination-select", "/deliver #{task_id} #{destination}")
      assert_includes redirected, "questions and approvals stay in the source"
      assert_equal source_id, current("101:0")
      assert_equal foreign_id, current("-10:7")
      assert_includes telegram_control("destination-question-refusal", "/answer #{question_id} Continue", chat: -10, topic: 7),
        "no longer available in this chat"
      assert_equal "awaiting_input", telegram_question_task(running).status
      assert_includes telegram_control("destination-member-refusal", "/stop #{task_id}", user: 102, chat: -10, topic: 7),
        "not available in this chat/topic"

      telegram_control("destination-new", "/new")
      selected_id = current("101:0")
      refute_equal source_id, selected_id
      assert_predicate source.fetch, :archived?
      restart_group_runtime(allowed: [101, 102])
      status = telegram_control("destination-status", "/status #{task_id}")
      assert_includes status, source_loop
      assert_includes telegram_control("destination-steer", "/steer #{task_id} Keep this same report and source context."),
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
      delivered_id, delivered = await("the final result reaches its original saved target after restart") do
        tick
        @telegram.messages.find do |_id, row|
          row.values_at(:chat_id, :message_thread_id) == ["101", nil] && row.fetch(:text, "").include?("Mock: destination-report")
        end
      end
      refute delivered.key?(:reply_parameters)
      assert_includes delivered.fetch(:text), task_id
      assert_empty @telegram.formal(-10)
      assert_equal selected_id, current("101:0")
      assert_equal before.values_at("public_id", "workspace_public_id", "answering_user_public_id"),
        @core.conversation(source_id, workspace_public_id: @workspace.public_id).values_at("public_id", "workspace_public_id", "answering_user_public_id")
      assert_equal note.fetch("public_id"), @core.memory_read(source_id, path: "conversation/source.md", workspace_public_id: @workspace.public_id).fetch("public_id")
      assert_equal "The source task keeps this note.", @core.memory_read(source_id, path: "conversation/source.md", workspace_public_id: @workspace.public_id).fetch("content")
      assert_empty @workspace.conversation(foreign_id).turns.list.items
      assert_empty @workspace.conversation(selected_id).turns.list.items

      bot_message = { "message_id" => delivered_id, "from" => @bot.merge("is_bot" => true), "text" => delivered.fetch(:text) }
      inputs_before = source.events(limit: 100).count { |event| event.type == "input_accepted" }
      refusal = telegram_control("destination-ordinary-reply", "Read more source notes", reply_to: bot_message)
      assert_includes refusal, "This is a delivered result"
      assert_equal inputs_before, source.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_includes telegram_control("destination-completed-copy", "/deliver #{task_id} #{destination}"), "latest completed result"
      tick
      copies = @telegram.messages.values.count do |row|
        row.values_at(:chat_id, :message_thread_id) == ["101", nil] && row.fetch(:text, "").include?("Mock: destination-report")
      end
      assert_equal 1, copies
      assert_includes telegram_control("destination-completed-stop", "/stop #{task_id}"), "Stop requested"
      assert_equal [source_loop], @bridge.stops
      refute_path_exists File.join(@home.root, "telegram", "state.json")
      assert_empty @logs
    ensure
      stop_group_work(source)
    end
  end
end
