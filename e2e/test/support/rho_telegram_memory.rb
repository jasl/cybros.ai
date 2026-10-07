module E2E
  module RhoTelegramMemory
    def test_group_memory_is_one_database_source_across_requesters_new_tasks_and_restart
      boot_runtime(allowed: [101, 102])
      marker = "group-fact-#{SecureRandom.hex(6)}"
      @runtime.consume(update("memory-owner", "@rho_bot\n!mock reply=ready -- start", chat: -10, topic: 7, mention: true))
      owner_id = current("-10:7")
      completed_reply(@workspace.conversation(owner_id))
      assert_includes telegram_control("memory-write", "/memory write group/team.md #{marker}", chat: -10, topic: 7), "Write completed"
      owner_row = @core.memory_read(owner_id, path: "group/team.md")
      @runtime.consume(update("memory-member", "@rho_bot\n!mock reply=member -- recall", user: 102, chat: -10, topic: 7, mention: true))
      member_id = current("-10:7", user: 102)
      member_turn = completed_reply(@workspace.conversation(member_id))
      assert_includes request_text(member_turn), marker
      assert_equal owner_row.fetch("public_id"), @core.memory_read(member_id, path: "group/team.md").fetch("public_id")
      error = assert_raises(Rho::Core::Refused) do
        @core.memory_write(member_id, path: "group/team.md", content: "forbidden replacement",
          expected_public_id: owner_row.fetch("public_id"), expected_lock_version: owner_row.fetch("lock_version"))
      end
      assert_equal "memory_read_only", error.code
      assert_equal marker, @core.memory_read(owner_id, path: "group/team.md").fetch("content")
      assert_includes telegram_control("memory-edit", "/memory edit #{JSON.generate(path: "group/team.md", old_text: marker, new_text: "#{marker}-edited")}", chat: -10, topic: 7), "Edit completed"
      assert_includes telegram_control("memory-grep", "/memory grep #{marker}", user: 102, chat: -10, topic: 7), "#{marker}-edited"

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
      @state = telegram_state
      boot_runtime(allowed: [101, 102])
      refute @core.followers.any? { |row| row.fetch("public_id") == owner_id }
      @runtime.consume(update("memory-cache-recall", "@rho_bot\n!mock reply=recovered-memory -- recall",
        chat: -10, topic: 7, mention: true))
      assert_equal owner_id, current("-10:7"), "the Nexus route survives the disposable follower cache"
      recovered = await("the saved route attaches with its database memory after cache loss") do
        @workspace.conversation(owner_id).turns.list.items.find do |turn|
          turn.status == "completed" && turn.active_variant&.content == "Mock: recovered-memory"
        end
      end
      assert_includes request_text(recovered), "#{marker}-edited"
      telegram_control("memory-new", "/new", chat: -10, topic: 7)
      fresh_id = current("-10:7")
      refute_equal owner_id, fresh_id
      assert_equal owner_row.fetch("public_id"), @core.memory_read(fresh_id, path: "group/team.md").fetch("public_id")
      room = @state.read.fetch("rooms").fetch("-10:7")
      anchor = room.fetch("memory_conversations").fetch(@workspace.public_id)
      assert_equal "#{marker}-edited", @workspace.conversation(anchor).memory.read("conversation/team.md").content
      refute_path_exists File.join(@home.root, "telegram", "state.json")
    end

    def test_external_private_memory_excludes_owner_notes_and_survives_new_conversations
      boot_runtime(allowed: [101, 102])
      secret = "owner-memory-#{SecureRandom.hex(6)}"
      @memory << @human.profile.memory.write("user/#{secret}.md", secret, expected_public_id: nil, expected_lock_version: nil)
      @runtime.consume(update("person-first", "!mock reply=first -- hello", user: 102, chat: 102))
      first_id = current("102:0")
      first_turn = completed_reply(@workspace.conversation(first_id))
      refute_includes request_text(first_turn), secret
      marker = "person-fact-#{SecureRandom.hex(6)}"
      assert_includes telegram_control("person-write", "/memory write person/preferences.md #{marker}", user: 102, chat: 102), "Write completed"
      telegram_control("person-new", "/new", user: 102, chat: 102)
      second_id = current("102:0")
      refute_equal first_id, second_id
      @runtime.consume(update("person-recall", "!mock reply=second -- recall", user: 102, chat: 102))
      request = request_text(completed_reply(@workspace.conversation(second_id)))
      assert_includes request, marker
      refute_includes request, secret
      assert_equal @core.memory_read(first_id, path: "person/preferences.md").fetch("public_id"),
        @core.memory_read(second_id, path: "person/preferences.md").fetch("public_id")
      error = assert_raises(Rho::Core::Refused) { @core.memory_read(second_id, path: "user/#{secret}.md") }
      assert_includes [403, 422], error.status
    end
  end
end
