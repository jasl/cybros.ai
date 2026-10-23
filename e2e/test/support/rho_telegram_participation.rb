require "support/mock_llm/server"
require "support/mock_llm/stack_upgrade"

module E2E
  # Room discussion reaches real InferenceRequests through the shipped Bridge and SDK.
  # Only Telegram IO and the provider's model answer are fixtures.
  module RhoTelegramParticipation
    def test_active_telegram_lost_append_ack_recovers_original_history_after_new_and_daemon_restart
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
      original_conversation = group_observer
      assert_equal original.fetch(:fields), @bridge.participation_starts.fetch(0).fetch(:fields)
      assert_equal original.fetch(:result).fetch("id"), @bridge.participation_starts.fetch(0).fetch(:result).fetch("id")
      assert_equal 1, participation_messages(answer).length
      telegram_control("new-after-accepted-append", "/new", chat: -10, topic: 7)
      selected = current("-10:7")
      refute_equal original_conversation.public_id, selected
      assert_predicate original_conversation.fetch, :archived?
      restart_group_runtime(allowed: [101, 102])
      replayed = await("the same accepted assistant input is recovered after restart") do
        tick
        @bridge.participation_records&.first
      end
      assert_equal appended, replayed
      rows = await_participation_history(answer, conversation: original_conversation)
      assert_equal 1, rows.count { |row| row.role == "assistant" }
      assert_observation_messages(rows)
      assert_equal 1, participation_messages(answer).length
      assert_equal [original.fetch(:result).fetch("id")], participation_shots.map(&:public_id)
      assert_equal 1, @workspace.inference_requests.fetch(original.fetch(:result).fetch("id")).usage_summary.request_count
      assert_empty @state.read.fetch("requests")
      assert_equal selected, current("-10:7")
      assert_empty @workspace.conversation(selected).turns.list.items
      assert_equal original_conversation.public_id, replayed.fetch(:conversation_id)
      assert_equal @workspace.public_id, replayed.fetch(:fields).fetch(:workspace_public_id)
      assert_equal ["telegram.participation_unavailable"] * 2, @logs.map(&:first)
    end

    def test_active_telegram_mode_off_and_new_discussion_cancel_pending_judgments_without_speech
      boot_runtime(allowed: [101, 102])
      stale_replies = []
      with_held_participation_provider do |directory|
        [7, 8].each_with_index do |topic, index|
          enable_active_room(topic: topic)
          stale = "Outdated advice #{topic}: " + "detail " * 130
          stale_replies << stale
          prompt = "#{MockLLM::StackUpgrade::MARKER}\n#{participation_prompt("reply", stale)}"
          receive(update(["stale-background", topic], prompt,
            user: 102, chat: -10, topic: topic))
          shot = await_participation_shot(count: index + 1)
          await("the real provider holds room #{topic}'s judgment") do
            requests = File.join(directory, "requests")
            File.file?(requests) && File.readlines(requests).length == index + 1
          end
          assert_equal "running", @workspace.inference_requests.fetch(shot.public_id).status
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
      end
      participation_ticks(6)
      stale_replies.each { |text| assert_empty participation_messages(text) }
      assert_equal 2, participation_shots.length
      assert_empty @bridge.participation_records || []
      assert_empty @state.read.fetch("requests")
      assert_empty @logs
    end

    private

      # Both real requests stay held until cancellation is publicly terminal.
      # The provider override belongs only to this journey's isolated world.
      def with_held_participation_provider
        directory = File.join(@root, "participation-provider")
        FileUtils.mkdir_p(directory)
        app = MockLLM::StackUpgrade.new(MockLLM::App.new, directory: directory)
        server = MockLLM::Server.new(app: app).start
        people = ActorProvisioning.world(@base_url)
        SessionSignInBudget.consume
        grant = CybrosAgent::Platform::Sessions.new(base_url: @base_url).create(email: people.owner_email, password: people.owner_password)
        SecretHygiene.register(grant.token)
        operator = CybrosAgent::PlatformClient.new(base_url: @base_url, credential: grant.token)
        provider = operator.model_providers.provider("dev")
        original = provider.configuration
        applied = provider.set_definition(definition: original.definition.merge("base_url" => server.base_url),
          expected_lock_version: original.provider.lock_version)
        assert_equal server.base_url, applied.definition.fetch("base_url")
        yield directory
      ensure
        begin
          File.write(File.join(directory, "release"), "finish\n") if directory
          server&.stop
        ensure
          begin
            if applied
              version = provider.configuration.provider.lock_version
              restored = if original.source == "catalog"
                provider.reset_definition(expected_lock_version: version)
              else
                provider.set_definition(definition: original.definition, expected_lock_version: version)
              end
              assert_equal original.definition, restored.definition
              assert_equal original.source, restored.source
            end
          ensure
            operator&.session&.revoke
          end
        end
      end

      def participation_prompt(decision, text = "")
        response = CGI.escape(JSON.generate("decision" => decision, "text" => text))
        "The group is discussing its deployment checklist.\n!mock raw_reply=#{response}"
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

      def await_participation_history(text, conversation: group_observer)
        await("the confirmed active reply is recorded in observation history") do
          tick
          rows = conversation.turns.list.items
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
