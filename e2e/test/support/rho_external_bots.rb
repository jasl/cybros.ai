module E2E
  # An admitted outside speaker controls model input. The captured declaration
  # limits memory and tools; published roles create children of the same Bot.
  module RhoExternalBots
    def test_external_bot_memory_is_per_bot_and_speaker_and_survives_a_new_conversation
      set_home(@alpha, @first_workspace)
      @core.ensure_bot_current(agent_public_id: @alpha.fetch("public_id"), operation_id: SecureRandom.uuid)
      owner = bot_conversation(@first_workspace, @alpha)
      configure(@alpha, chat_id: 101)
      await_connected(@alpha)
      send_message(@alpha, 1, "!mock reply=owner-ready -- Establish the owner's Speaker")
      await_reply(@alpha, "Mock: owner-ready")
      owner_turn = external_turn(owner, "owner-ready")
      external_seed(owner, "agent/private.md", "owner-agent-private-fact")
      external_seed(owner, "speaker/preferences.md", "owner-speaker-private-fact", speaker_public_id: external_speaker(owner_turn))
      shared = @human.workspace(@first_workspace).memory.write("workspace/knowledge.md", "Published shared knowledge",
        expected_public_id: nil, expected_lock_version: nil)
      external_connect(@alpha, chat_id: -201, users: [202, 303])
      external_connect(@beta, chat_id: -202, users: [202])
      external_new(@alpha, 2, previous: owner.public_id)

      alpha_202, first = external_message(@alpha, 3, 202, [
        ["memory_read", { "path" => "workspace/knowledge.md" }],
        ["memory_write", { "path" => "speaker/preferences.md", "content" => "Alpha visitor 202 fact" }],
        ["memory_write", { "path" => "conversation/task.md", "content" => "Alpha current task fact" }],
        ["memory_read", { "path" => "agent/private.md" }],
        ["memory_read", { "path" => "user/private.md" }],
        ["memory_write", { "path" => "workspace/knowledge.md", "content" => "must not replace shared knowledge" }],
      ], reply: "alpha-202-saved")
      assert_equal "Published shared knowledge", external_tool_output(first, "memory_read", occurrence: 0)
      assert_match(/\Amemory_scope_unavailable:/, external_tool_output(first, "memory_read", occurrence: 1, error: true))
      assert_match(/\Amemory_scope_unavailable:/, external_tool_output(first, "memory_read", occurrence: 2, error: true))
      assert_match(/\Amemory_read_only:/, external_tool_output(first, "memory_write", occurrence: 2, error: true))
      assert_equal shared.to_h, @human.workspace(@first_workspace).memory.read("workspace/knowledge.md").to_h
      refute_includes external_request_text(first), "owner-agent-private-fact"
      refute_includes external_request_text(first), "owner-speaker-private-fact"
      bindings = alpha_202.fetch.memory_context.fetch("bindings")

      alpha_303, other = external_message(@alpha, 4, 303, [
        ["memory_read", { "path" => "speaker/preferences.md" }],
        ["memory_write", { "path" => "speaker/preferences.md", "content" => "Alpha visitor 303 fact" }],
      ], reply: "alpha-303-saved", prior_answers: 6)
      beta_202, beta_turn = external_message(@beta, 5, 202, [
        ["memory_write", { "path" => "speaker/preferences.md", "content" => "Beta visitor 202 fact" }],
      ], reply: "beta-202-saved")
      assert_equal alpha_202.public_id, alpha_303.public_id, "all members share the Bot's current group conversation"
      assert_match(/\Amemory_not_found:/, external_tool_output(other, "memory_read", error: true))
      assert_equal external_speaker(first), external_speaker(beta_turn), "one person has one ingress Speaker across Bots"
      refute_equal external_speaker(first), external_speaker(other)
      documents = [[alpha_202, first], [alpha_303, other], [beta_202, beta_turn]].map do |chat, turn|
        external_memory(chat, turn, "speaker/preferences.md")
      end
      assert_equal 3, documents.map { |row| row.fetch("public_id") }.uniq.length
      assert_equal ["Alpha visitor 202 fact", "Alpha visitor 303 fact", "Beta visitor 202 fact"], documents.map { |row| row.fetch("content") }
      assert_equal bindings, alpha_303.fetch.memory_context.fetch("bindings"), "per-input Speakers never rebind the shared conversation"
      assert_equal %w[conversation speaker workspace], first.active_variant.memory_context.fetch("bindings").map { |binding| binding.fetch("name") }.sort

      @daemon.stop
      @daemon.start
      @core = Rho::Core.new(home: @home)
      [@alpha, @beta].each { |bot| await_connected(bot) }
      external_new(@alpha, 6, previous: alpha_202.public_id)
      fresh, recalled = external_message(@alpha, 7, 202, [
        ["memory_read", { "path" => "speaker/preferences.md" }],
        ["memory_read", { "path" => "conversation/task.md" }],
        ["session_read", { "session_id" => beta_202.public_id }],
      ], reply: "alpha-202-recalled")
      refute_equal alpha_202.public_id, fresh.public_id
      assert_predicate alpha_202.fetch, :archived?
      assert_equal beta_202.public_id, bot_current(@beta).fetch("public_id")
      assert_equal documents.first.fetch("public_id"), external_memory(fresh, recalled, "speaker/preferences.md").fetch("public_id")
      assert_equal "Alpha visitor 202 fact", external_tool_output(recalled, "memory_read", occurrence: 0)
      assert_match(/\Amemory_not_found:/, external_tool_output(recalled, "memory_read", occurrence: 1, error: true))
      assert_match(/\Anot_found:/, external_tool_output(recalled, "session_read", error: true))
    end

    def test_external_delegation_uses_a_role_with_private_child_memory_and_the_source_bot
      private_bot = create_bot("private")
      external_connect(@alpha, chat_id: -201, users: [202])
      external_connect(@beta, chat_id: -202, users: [202])
      beta, beta_turn = external_message(@beta, 1, 202, [
        ["memory_write", { "path" => "speaker/preferences.md", "content" => "Beta knows this visitor" }],
      ], reply: "beta-ready")
      identities = @daemon.control(:get, "/agents").fetch("bots").map { |row| row.fetch("public_id") }.sort
      beta_messages = bot_messages(@beta)
      brief = external_script([
        ["memory_read", { "path" => "speaker/preferences.md" }],
        ["memory_read", { "path" => "workspace/knowledge.md" }],
        ["memory_write", { "path" => "conversation/delegated.md", "content" => "Learned in the delegated child" }],
      ], reply: "worker-child-result")
      parent, parent_turn = external_message(@alpha, 2, 202, [
        ["spawn", { "agent" => private_bot.fetch("public_id"), "prompt" => brief, "label" => "private" }],
        ["spawn", { "agent" => @beta.fetch("public_id"), "prompt" => brief, "label" => "peer" }],
        ["spawn", { "prompt" => brief, "label" => "missing" }],
        ["spawn", { "role" => "worker", "prompt" => brief, "label" => "specialist", "wait" => true }],
      ], reply: "alpha-parent-synthesis")
      attempts = @human.workspace(@first_workspace).runs.run(parent_turn.active_variant.run_public_id).fetch.tasks.select { |task| task.tool_name == "spawn" }
      assert_equal 4, attempts.length
      assert_equal %w[failed failed failed completed], attempts.map(&:status)
      attempts.first(3).each { |task| assert_equal "approval_denied", task.error.fetch("key") }
      child = @daemon.await("the external worker child is created") do
        parent.children.items.find { |row| row.parent&.label == "specialist" }
      end
      child_chat = external_chat(child.public_id)
      assert_equal [child.public_id], parent.children.items.map(&:public_id), "refused targets create no children"
      child_turn = external_turn(child_chat, "worker-child-result")
      assert_equal @alpha.fetch("public_id"), child.answering_user_public_id
      assert child_chat.fetch.execution_declaration_present
      assert_equal ["conversation"], child_turn.active_variant.memory_context.fetch("bindings").map { |binding| binding.fetch("name") }
      assert_match(/\Amemory_scope_unavailable:/, external_tool_output(child_turn, "memory_read", occurrence: 0, error: true))
      assert_match(/\Amemory_scope_unavailable:/, external_tool_output(child_turn, "memory_read", occurrence: 1, error: true))
      assert_equal "Learned in the delegated child", child_chat.memory.read("conversation/delegated.md").content
      assert_empty parent.memory.list.select { |row| row.path.start_with?("conversation/") }
      assert_equal "Beta knows this visitor", external_memory(beta, beta_turn, "speaker/preferences.md").fetch("content")
      assert_equal identities, @daemon.control(:get, "/agents").fetch("bots").map { |row| row.fetch("public_id") }.sort
      assert_equal beta_messages, bot_messages(@beta), "role execution never redirects replies to a peer Bot"
      assert_equal 1, bot_messages(@alpha).count { |message| message["text"] == "Mock: alpha-parent-synthesis" }
    end

    def test_presets_are_portable_configuration_and_bot_duplicate_creates_a_fresh_identity
      external_connect(@alpha, chat_id: -201, users: [202])
      source, source_turn = external_message(@alpha, 1, 202, [
        ["memory_write", { "path" => "speaker/private.md", "content" => "source-only-memory-content" }],
      ], reply: "source-connected")
      before = @daemon.control(:get, "/agents").fetch("bots")
      current = bot_current(@alpha)
      target = telegram_status(@alpha).fetch("configuration")
      %w[md json].each do |format|
        exported = @daemon.control(:get, "/presets/export?#{URI.encode_www_form(public_id: @external_preset.fetch("public_id"), format: format)}").fetch("content")
        [@alpha.fetch("public_id"), @external_preset.fetch("public_id"), @first_workspace, self.class::TOKEN,
          "source-only-memory-content", "audience", "welcome_message"].each { |private_value| refute_includes exported, private_value }
        imported_name = "Imported #{format} #{SecureRandom.hex(4)}"
        imported = @daemon.control(:post, "/presets/import_document", body: {
          "format" => format, "content" => exported, "name" => imported_name,
        }).fetch("presets").find { |row| row.fetch("name") == imported_name }
        refute_equal @external_preset.fetch("public_id"), imported.fetch("public_id")
        assert_equal @external_preset.fetch("configuration"), imported.fetch("configuration")
        assert_nil imported.fetch("role")
      end
      preset_name = "Preset duplicate #{SecureRandom.hex(4)}"
      preset_copy = @daemon.control(:post, "/presets/duplicate", body: {
        "public_id" => @external_preset.fetch("public_id"), "name" => preset_name,
      }).fetch("presets").find { |row| row.fetch("name") == preset_name }
      assert_equal @external_preset.fetch("configuration"), preset_copy.fetch("configuration")
      assert_equal before, @daemon.control(:get, "/agents").fetch("bots")
      assert_equal current, bot_current(@alpha)
      assert_equal target, telegram_status(@alpha).fetch("configuration")

      duplicate_name = "duplicate-#{SecureRandom.hex(4)}"
      copied = @daemon.control(:post, "/agents/duplicate", body: {
        "source_name" => @alpha.fetch("name"), "name" => duplicate_name, "audience" => "owner",
      }).fetch("agent")
      refute_equal @alpha.fetch("public_id"), copied.fetch("public_id")
      assert_equal "owner", external_bot_row(copied).fetch("audience")
      assert_equal @external_preset.fetch("public_id"), external_bot_row(copied).fetch("preset_public_id")
      assert_nil external_bot_row(copied).fetch("home_workspace_public_id")
      assert_nil telegram_status(copied).dig("configuration", "connection_public_id")
      assert_nil telegram_status(copied).dig("configuration", "target")
      assert_nil bot_current(copied)
      assert_empty @core.bot_history(agent_public_id: copied.fetch("public_id")).fetch("conversations")
      set_home(copied, @first_workspace)
      @core.ensure_bot_current(agent_public_id: copied.fetch("public_id"), operation_id: SecureRandom.uuid)
      duplicate_chat = bot_conversation(@first_workspace, copied)
      assert_empty @core.memory_list(duplicate_chat.public_id, path: "speaker", speaker_public_id: external_speaker(source_turn),
        workspace_public_id: @first_workspace)
      assert_equal "source-only-memory-content", external_memory(source, source_turn, "speaker/private.md").fetch("content")
      refused = @daemon.control(:put, "/agents/settings", body: { "agent_public_id" => @alpha.fetch("public_id"), "audience" => "owner" })
      assert_equal "bot_audience_fixed", refused.dig("error", "code")
      refused = @daemon.control(:post, "/agents/duplicate", body: {
        "source_name" => @alpha.fetch("name"), "name" => duplicate_name, "audience" => "owner",
      })
      assert_equal "name_taken", refused.dig("error", "code")
      assert_equal copied.fetch("public_id"), external_bot_row(copied).fetch("public_id")
    end

    private

      def external_connect(bot, chat_id:, users:)
        @external_preset ||= @daemon.control(:post, "/presets", body: {
          "name" => "External Telegram", "description" => "Answers admitted group members.",
          "configuration" => { "model" => self.class::MODEL, "tools" => nil,
            "system_prompt" => "Answer the current visitor using the permitted knowledge." },
        }).fetch("presets").find { |row| row.fetch("name") == "External Telegram" }
        selected = @daemon.control(:put, "/agents/settings", body: { "agent_public_id" => bot.fetch("public_id"),
          "preset_public_id" => @external_preset.fetch("public_id"), "audience" => "external" })
        assert_equal @external_preset.fetch("public_id"), selected.fetch("preset_public_id")
        set_home(bot, @first_workspace)
        configure(bot, chat_id: chat_id)
        await_connected(bot)
        access = @daemon.control(:post, "/telegram/access", body: { "agent_public_id" => bot.fetch("public_id"),
          "list" => "allowed_chats", "action" => "add", "id" => chat_id.to_s })
        assert_includes access.fetch("access").fetch("allowed_chats"), chat_id.to_s
        users.each do |user|
          access = @daemon.control(:post, "/telegram/access", body: { "agent_public_id" => bot.fetch("public_id"),
            "list" => "allowed_users", "action" => "add", "id" => user.to_s })
          refute access.key?("error"), access.inspect
        end
      end

      def external_new(bot, id, previous:)
        send_message(bot, id, "/new")
        @daemon.await("the owner starts a new shared Bot conversation") do
          selected = bot_current(bot)
          selected if selected && selected.fetch("public_id") != previous
        end
      end

      def external_message(bot, id, user, calls, reply:, prior_answers: 0)
        send_message(bot, id, external_script(calls, reply: reply, prior_answers: prior_answers), user: user)
        await_reply(bot, "Mock: #{reply}")
        chat = bot_conversation(@first_workspace, bot)
        [chat, external_turn(chat, reply)]
      end

      def external_script(calls, reply:, prior_answers: 0)
        # MockLLM counts tool answers in the complete shared transcript.
        scripted = Array.new(prior_answers) { ["memory_ls", {}] } + calls
        script = scripted.map { |name, input| "#{name}:#{CGI.escape(JSON.generate(input))}" }.join(",")
        directive = script.empty? ? "" : "tool_call=#{script} "
        "!mock #{directive}reply=#{CGI.escape(reply)} -- use the current visitor's permitted context"
      end

      def external_chat(id) = @human.workspace(@first_workspace).conversation(id)

      def external_turn(chat, reply)
        @daemon.await("the completed reply #{reply}") do
          rows = chat.turns.list.items
          failed = rows.find { |turn| turn.status == "failed" }
          flunk "External Bot turn failed: #{failed.to_h.inspect}" if failed
          rows.find { |turn| turn.status == "completed" && turn.text == "Mock: #{reply}" }
        end
      end

      def external_speaker(turn)
        turn.active_variant.memory_context.fetch("bindings").find { |binding| binding.fetch("name") == "speaker" }.fetch("speaker_public_id")
      end

      def external_memory(chat, turn, path)
        @core.memory_read(chat.public_id, path: path, speaker_public_id: external_speaker(turn), workspace_public_id: @first_workspace)
      end

      def external_seed(chat, path, content, speaker_public_id: nil)
        @core.memory_write(chat.public_id, path: path, content: content, expected_public_id: nil,
          expected_lock_version: nil, speaker_public_id: speaker_public_id, workspace_public_id: @first_workspace)
      end

      def external_request_text(turn)
        request = @human.workspace(@first_workspace).runs.run(turn.active_variant.run_public_id).tasks_context("r1").request
        request.entries.flat_map { |entry| entry.fetch("parts", []).filter_map { |part| part["text"] } }.join("\n")
      end

      def external_tool_output(turn, name, occurrence: 0, error: false)
        run = @human.workspace(@first_workspace).runs.run(turn.active_variant.run_public_id)
        task = run.fetch.tasks.select { |row| row.tool_name == name }.fetch(occurrence)
        assert_equal "completed", task.status
        assert_equal error, task.result.fetch("is_error", false), task.to_h.inspect
        run.task(task.key).output
      end

      def external_bot_row(bot)
        @daemon.control(:get, "/agents").fetch("bots").find { |row| row.fetch("public_id") == bot.fetch("public_id") }
      end
  end
end
