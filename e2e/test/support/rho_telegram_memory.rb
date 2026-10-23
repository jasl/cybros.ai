module E2E
  module RhoTelegramMemory
    def test_group_memory_is_shared_while_each_request_selects_its_own_speaker_memory
      boot_runtime(allowed: [101, 102, 103])
      marker = "group-fact-#{SecureRandom.hex(6)}"
      receive(update("memory-owner", "@rho_bot\n!mock reply=ready -- start", chat: -10, topic: 7, mention: true))
      conversation_id = current("-10:7")
      chat = @workspace.conversation(conversation_id)
      completed_reply(chat)
      assert_includes telegram_control("memory-write", "/memory write conversation/team.md #{marker}", chat: -10, topic: 7), "Write completed"
      shared = @core.memory_read(conversation_id, path: "conversation/team.md")
      receive(update("memory-member", "@rho_bot\n!mock reply=member -- recall", user: 102, chat: -10, topic: 7, mention: true))
      assert_equal conversation_id, current("-10:7", user: 102)
      member_turn = memory_reply(chat, "member")
      assert_includes request_text(member_turn), marker
      assert_includes telegram_control("memory-edit", "/memory edit #{JSON.generate(path: "conversation/team.md", old_text: marker, new_text: "#{marker}-edited")}",
        user: 102, chat: -10, topic: 7), "Edit completed"
      assert_includes telegram_control("memory-grep", "/memory grep #{marker}", chat: -10, topic: 7), "#{marker}-edited"
      assert_equal shared.fetch("public_id"), @core.memory_read(conversation_id, path: "conversation/team.md").fetch("public_id")

      assert_includes telegram_control("alice-memory", "/memory write speaker/preferences.md Alice prefers tea", user: 102, chat: -10, topic: 7), "Write completed"
      assert_includes telegram_control("bob-memory", "/memory write speaker/preferences.md Bob prefers coffee", user: 103, chat: -10, topic: 7), "Write completed"
      speakers = state_for("-10:7").read.fetch("speakers")
      alice_id, bob_id = speakers.values_at("102", "103")
      refute_equal alice_id, bob_id
      alice = @core.memory_read(conversation_id, path: "speaker/preferences.md", speaker_public_id: alice_id)
      bob = @core.memory_read(conversation_id, path: "speaker/preferences.md", speaker_public_id: bob_id)
      assert_equal "Alice prefers tea", alice.fetch("content")
      assert_equal "Bob prefers coffee", bob.fetch("content")
      refute_equal alice.fetch("public_id"), bob.fetch("public_id")
      assert_includes telegram_control("alice-recall", "/memory read speaker/preferences.md", user: 102, chat: -10, topic: 7), "Alice prefers tea"
      assert_includes telegram_control("bob-recall", "/memory read speaker/preferences.md", user: 103, chat: -10, topic: 7), "Bob prefers coffee"
      bindings = @core.conversation(conversation_id).fetch("memory_context")

      @runtime.close
      cache = @home.host_cache_path(@client.profile.fetch.member.public_id)
      @daemon.stop
      assert_path_exists cache
      File.unlink(cache)
      @daemon.start
      await("rho restores its workspace without a follower cache") do
        @daemon.status.dig("workspace", "public_id") == @workspace.public_id
      end
      @daemon.await_announced(address: "runner")
      connect_bridge(@workspace.public_id)
      boot_runtime(allowed: [101, 102, 103])
      receive(update("memory-cache-recall", "@rho_bot\n!mock reply=recovered-memory -- recall", user: 102, chat: -10, topic: 7, mention: true))
      assert_equal conversation_id, current("-10:7"), "the Bot current survives the disposable follower cache"
      recovered = memory_reply(chat, "recovered-memory")
      assert_includes request_text(recovered), "#{marker}-edited"
      assert_includes request_text(recovered), "Alice prefers tea"
      refute_includes request_text(recovered), "Bob prefers coffee"
      assert_equal bindings, @core.conversation(conversation_id).fetch("memory_context"), "request selection never rebinds conversation memory"
      telegram_control("memory-new", "/new", chat: -10, topic: 7)
      fresh_id = current("-10:7")
      refute_equal conversation_id, fresh_id
      assert_equal alice.fetch("public_id"), @core.memory_read(fresh_id, path: "speaker/preferences.md", speaker_public_id: alice_id).fetch("public_id")
      error = assert_raises(Rho::Core::Refused) { @core.memory_read(fresh_id, path: "conversation/team.md") }
      assert_equal 404, error.status
      assert_equal "#{marker}-edited", @core.memory_read(conversation_id, path: "conversation/team.md").fetch("content")
      refute_path_exists File.join(@home.root, "telegram", "state.json")
      assert_empty @logs
    end

    private

      def memory_reply(chat, answer)
        await("the memory reply #{answer}") do
          tick
          chat.turns.list.items.find do |turn|
            turn.kind == "direct_reply" && turn.status == "completed" && turn.active_variant&.content == "Mock: #{answer}"
          end
        end
      end
  end
end
