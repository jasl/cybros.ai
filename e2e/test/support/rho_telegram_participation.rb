module E2E
  # Room discussion reaches real InferenceRequests through the shipped Bridge and SDK.
  # Only Telegram IO and the provider's model answer are fixtures.
  module RhoTelegramParticipation
    def test_active_telegram_mode_is_owner_controlled_room_scoped_and_quiet_is_terminal
      boot_runtime(allowed: [101, 102, 103])
      @telegram.provide_member(-10, 103, status: "administrator")
      assert_includes telegram_control("mode-default", "/mode", user: 102, chat: -10, topic: 7), "assistant"
      assert_includes telegram_control("mode-refused", "/mode active", user: 103, chat: -10, topic: 7), "Only the bot owner"
      assert_includes telegram_control("mode-active", "/mode active", chat: -10, topic: 7), "active"
      paused = telegram_control("mode-paused", "/settings", user: 102, chat: -10, topic: 7)
      assert_includes paused, "Observe: off"
      assert_match(/paused/i, paused)
      assert_includes telegram_control("mode-other-topic", "/mode status", user: 102, chat: -10, topic: 8), "assistant"
      assert_includes telegram_control("mode-no-topic", "/mode", user: 102, chat: -10), "assistant"

      receive(update("unobserved-background", participation_prompt("quiet"), user: 102, chat: -10, topic: 7))
      telegram_control("observe-active", "/observe on", chat: -10, topic: 7)
      participation_ticks(6)
      assert_empty participation_shots
      assert_empty @state.read.fetch("routes")

      messages = @telegram.messages.keys
      background = participation_prompt("quiet")
      receive(update("quiet-background", background, user: 102, chat: -10, topic: 7))
      await("the observation is available before the memory-only preview") { group_observer.turns.list.items.length == 1 }
      marker = "group-release-fact-#{SecureRandom.hex(6)}"
      secret = "owner-private-fact-#{SecureRandom.hex(6)}"
      @memory << @human.profile.memory.write("user/#{secret}.md", secret, expected_public_id: nil, expected_lock_version: nil)
      @core.memory_write(group_observer.public_id, path: "conversation/release.md", content: marker,
        expected_public_id: nil, expected_lock_version: nil, workspace_public_id: @workspace.public_id)
      reference = @bridge.participation_memory(group_observer.public_id, model: self.class::MODEL,
        workspace_public_id: @workspace.public_id)
      assert_includes reference, marker
      refute_includes reference, secret
      refute_includes reference, "The group is discussing its deployment checklist."
      shot = await_participation_shot
      terminal = await_participation_terminal(shot.public_id)
      assert_equal "completed", terminal.status
      assert_nil terminal.result.finish_quality
      assert_equal({ "decision" => "quiet", "text" => "" }, JSON.parse(terminal.output_text))
      participation_ticks(6)
      assert_equal [shot.public_id], participation_shots.map(&:public_id)
      assert_equal 1, terminal.usage_summary.request_count
      prompt = @bridge.participation_starts.fetch(0).fetch(:fields).fetch(:prompt)
      assert_equal 1, prompt.scan(marker).length
      assert_equal 1, prompt.scan("The group is discussing its deployment checklist.").length
      refute_includes prompt, secret
      assert_equal messages, @telegram.messages.keys, "a quiet decision sends no Telegram message"
      assert_empty @bridge.participation_records || []
      assert_empty @state.read.fetch("requests")
      assert_empty @state.read.fetch("routes")
      rows = group_observer.turns.list.items
      assert_equal 1, rows.length
      assert_observation_messages(rows)
      assert_empty @logs
    end

    def test_active_telegram_reply_records_rho_history_once_and_member_reply_keeps_read_only_authority
      boot_runtime(allowed: [101, 102])
      telegram_control("member-model", "/model dev/mock-text-only", user: 102, chat: -10, topic: 7)
      enable_active_room
      answer = "The deployment checklist needs a rollback step."
      receive(update("reply-background", participation_prompt("reply", answer), user: 102, chat: -10, topic: 7))
      message = group_bot_message(answer)
      sent = @telegram.messages.fetch(message.fetch("message_id"))
      refute sent.key?(:parse_mode)
      refute sent.key?(:reply_parameters)
      assert_empty @bridge.participation_records || [], "the member replies before the confirmed message is appended"
      assert_empty @state.read.fetch("requests")
      incoming = update("member-reply-to-active", "!mock reply=member-follow-up -- Explain that rollback step.",
        user: 102, chat: -10, topic: 7)
      incoming.fetch("message")["reply_to_message"] = message
      receive(incoming)
      conversation = @workspace.conversation(current("-10:7", user: 102))
      turn = completed_reply(conversation)
      assert_includes request_text(turn), answer
      assert_equal "Mock: member-follow-up", group_bot_message("Mock: member-follow-up").fetch("text")
      assert_permission_rounds_read_only(@workspace.runs.run(turn.active_variant.run_public_id))
      refute_equal group_observer.public_id, conversation.public_id

      rows = await_participation_history(answer)
      assistant = rows.find { |row| row.role == "assistant" }
      group_profile = @client.profile.agents.list.find { |profile| profile.name == "telegram-group" }
      assert_equal group_profile.public_id, assistant.speaker.user_public_id
      assert_equal "agent", assistant.speaker.kind
      assert_observation_messages(rows)
      assert_equal 2, rows.length
      shots = participation_shots
      assert_equal 1, shots.length
      assert_equal "mock-text", shots.first.model.model_ref
      assert_equal self.class::MODEL, @bridge.participation_starts.fetch(0).fetch(:fields).fetch(:model)
      assert_equal @workspace.public_id, @bridge.participation_starts.fetch(0).fetch(:fields).fetch(:workspace_public_id)

      receive(update("reply-followup-background", "Another detail can wait for the cooldown.", user: 102, chat: -10, topic: 7))
      participation_ticks(6)
      assert_equal [shots.first.public_id], participation_shots.map(&:public_id)
      assert_equal 1, participation_messages(answer).length
      assert_empty @logs
    ensure
      stop_group_work(conversation)
    end

    def test_active_telegram_create_and_assistant_append_recover_lost_acks_across_daemon_restarts
      boot_runtime(allowed: [101, 102])
      enable_active_room
      answer = "Keep the rollback steps next to the release checklist."
      @bridge.lose_next_participation_ack = true
      receive(update("lost-create", participation_prompt("reply", answer), user: 102, chat: -10, topic: 7))
      original = await("the real InferenceRequest create is accepted before its reply is lost") do
        tick
        @bridge.participation_starts&.first
      end
      assert_equal [original.fetch(:result).fetch("id")], participation_shots.map(&:public_id)
      restart_group_runtime(allowed: [101, 102])
      @bridge.lose_next_participation_record_ack = true
      appended = await("the real assistant message is accepted before its reply is lost") do
        tick
        @bridge.participation_records&.first
      end
      assert_equal original.fetch(:fields), @bridge.participation_starts.fetch(0).fetch(:fields)
      assert_equal original.fetch(:result).fetch("id"), @bridge.participation_starts.fetch(0).fetch(:result).fetch("id")
      assert_equal 1, participation_messages(answer).length
      restart_group_runtime(allowed: [101, 102])
      replayed = await("the same accepted assistant input is recovered after restart") do
        tick
        @bridge.participation_records&.first
      end
      assert_equal appended, replayed
      rows = await_participation_history(answer)
      assert_equal 1, rows.count { |row| row.role == "assistant" }
      assert_observation_messages(rows)
      assert_equal 1, participation_messages(answer).length
      assert_equal [original.fetch(:result).fetch("id")], participation_shots.map(&:public_id)
      assert_equal 1, @workspace.inference_requests.fetch(original.fetch(:result).fetch("id")).usage_summary.request_count
      assert_empty @state.read.fetch("requests")
      assert_empty @state.read.fetch("routes")
      assert_equal ["telegram.participation_unavailable"] * 2, @logs.map(&:first)
    end

    def test_active_telegram_mode_off_and_new_discussion_cancel_pending_judgments_without_speech
      boot_runtime(allowed: [101, 102])
      [7, 8].each do |topic|
        enable_active_room(topic: topic)
        stale = "Outdated advice #{topic}: " + "detail " * 130
        receive(update(["stale-background", topic], participation_prompt("reply", stale, slow: true),
          user: 102, chat: -10, topic: topic))
        shot = await_participation_shot(count: topic == 7 ? 1 : 2)
        await("the real provider is still streaming the room judgment") do
          tick
          @workspace.inference_requests.fetch(shot.public_id).status == "running"
        end
        if topic == 7
          telegram_control("mode-stop-stream", "/mode assistant", chat: -10, topic: topic)
        else
          receive(update("new-background", "The question changed while that answer was being prepared.",
            user: 102, chat: -10, topic: topic))
        end
        terminal = await_participation_terminal(shot.public_id)
        assert_equal "canceled", terminal.status
        assert_empty participation_messages(stale)
        telegram_control(["end-stale-room", topic], "/mode assistant", chat: -10, topic: topic)
      end
      participation_ticks(6)
      assert_equal 2, participation_shots.length
      assert_empty @bridge.participation_records || []
      assert_empty @state.read.fetch("requests")
      assert_empty @logs
    end

    private

      def participation_prompt(decision, text = "", slow: false)
        response = CGI.escape(JSON.generate("decision" => decision, "text" => text))
        "The group is discussing its deployment checklist.\n!mock raw_reply=#{response}#{" stream_chunk_delay=0.2" if slow}"
      end

      def enable_active_room(topic: 7)
        telegram_control(["enable-observe", topic], "/observe on", chat: -10, topic: topic)
        telegram_control(["enable-active", topic], "/mode active", chat: -10, topic: topic)
      end

      def participation_shots = @workspace.inference_requests.list(limit: 100).items

      def await_participation_shot(count: 1)
        await("#{count} public room InferenceRequests") do
          tick
          rows = participation_shots
          rows.max_by(&:created_at) if rows.length == count
        end
      end

      def await_participation_terminal(id)
        await("the public room InferenceRequest finishes") do
          tick
          row = @workspace.inference_requests.fetch(id)
          row if row.finished?
        end
      end

      def await_participation_history(text)
        await("the confirmed active reply is recorded in observation history") do
          tick
          rows = group_observer.turns.list.items
          rows if rows.any? { |row| row.role == "assistant" && row.active_variant.content == text }
        end
      end

      def participation_messages(text)
        @telegram.messages.values.select { |row| row[:chat_id] == "-10" && row[:text] == text }
      end

      def participation_ticks(seconds)
        seconds.times do
          tick
          sleep 1
        end
      end

      def assert_observation_messages(rows)
        rows.each do |row|
          assert_equal "message", row.kind
          assert_equal "completed", row.status
          assert_nil row.active_variant.run_public_id
          assert_nil row.active_variant.model
        end
      end
  end
end
