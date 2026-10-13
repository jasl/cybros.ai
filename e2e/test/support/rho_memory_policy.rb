module E2E
  # Scripted model calls exercise the real memory tools and sealed requests.
  # These journeys prove policy delivery and persistence, not semantic extraction.
  module RhoMemoryPolicy
    def test_the_owner_bot_sends_memory_policy_and_saves_a_task_fact_through_model_tools
      boot_runtime(allowed: [101])
      path = "conversation/memory-policy.md"
      content = "Task fact: verified the release checklist.\nSource: #{SecureRandom.hex(6)}.\n"
      prompt = memory_policy_prompt([
        ["memory_ls", { "path" => "conversation/" }],
        ["memory_write", { "path" => path, "content" => content }],
        ["memory_read", { "path" => path }],
      ], reply: "task-fact-saved")
      receive(update("policy-main", prompt))
      chat = @workspace.conversation(current("101:0"))
      turn = memory_policy_reply(chat, "task-fact-saved")

      assert_includes request_text(turn), Rho::MemoryPolicy::PROMPT
      assert_includes successful_tool_output(turn, "memory_ls"), "No memory documents."
      assert_includes successful_tool_output(turn, "memory_write"), "Wrote #{path}"
      assert_equal content, successful_tool_output(turn, "memory_read")
      assert_equal content, chat.memory.read(path).content
      assert_empty @logs
    end

    def test_group_model_memory_is_shared_and_corrected_but_a_new_conversation_has_its_own_notes
      boot_runtime(allowed: [101, 102])
      path = "conversation/team.md"
      original = "Release day: Tuesday.\nKeep: blue marker #{SecureRandom.hex(6)}.\n"
      corrected = original.sub("Tuesday", "Thursday")
      prompt = memory_policy_prompt([
        ["memory_ls", { "path" => "conversation/" }],
        ["memory_write", { "path" => path, "content" => original }],
        ["memory_read", { "path" => path }],
      ], reply: "group-fact-saved")
      receive(update("policy-group-save", "@rho_bot\n#{prompt}", chat: -10, topic: 7, mention: true))
      owner_id = current("-10:7")
      owner = @workspace.conversation(owner_id)
      saved = memory_policy_reply(owner, "group-fact-saved")
      assert_includes request_text(saved), Rho::MemoryPolicy::PROMPT
      assert_includes successful_tool_output(saved, "memory_ls"), "No memory documents."
      assert_includes successful_tool_output(saved, "memory_write"), "Wrote #{path}"
      assert_equal original, successful_tool_output(saved, "memory_read")
      document = owner.memory.read(path)
      assert_equal original, document.content

      # The fake counts every earlier tool answer in the assembled history.
      # The first turn made three calls; these next three start at answer 3.
      correction = memory_policy_prompt([
        ["memory_read", { "path" => path }],
        ["memory_edit", { "path" => path, "old_text" => "Release day: Tuesday.", "new_text" => "Release day: Thursday." }],
        ["memory_grep", { "pattern" => "Release day:", "path" => "conversation/" }],
      ], reply: "group-fact-corrected", prior_answers: 3)
      receive(update("policy-group-correct", "@rho_bot\n#{correction}", chat: -10, topic: 7, mention: true))
      correction_turn = memory_policy_reply(owner, "group-fact-corrected")
      assert_includes request_text(correction_turn), Rho::MemoryPolicy::PROMPT
      assert_equal original, successful_tool_output(correction_turn, "memory_read")
      assert_includes successful_tool_output(correction_turn, "memory_edit"), "Edited #{path}"
      assert_equal "#{path}:1: Release day: Thursday.", successful_tool_output(correction_turn, "memory_grep")
      changed = owner.memory.read(path)
      assert_equal document.public_id, changed.public_id
      assert_equal corrected, changed.content, "a correction preserves the unrelated confirmed fact"

      recall = memory_policy_prompt([
        ["memory_read", { "path" => path }],
        ["memory_grep", { "pattern" => "Release day:", "path" => "conversation/" }],
        ["memory_write", { "path" => "conversation/bob.md", "content" => "Bob confirmed the shared release fact." }],
      ], reply: "group-fact-recalled", prior_answers: 6)
      receive(update("policy-group-recall", "@rho_bot\n#{recall}", user: 102, chat: -10, topic: 7, mention: true))
      reader_id = current("-10:7", user: 102)
      assert_equal owner_id, reader_id, "all admitted group members share one current conversation"
      reader = @workspace.conversation(reader_id)
      recalled = memory_policy_reply(reader, "group-fact-recalled")
      assert_includes request_text(recalled), Rho::MemoryPolicy::PROMPT
      assert_equal corrected, successful_tool_output(recalled, "memory_read")
      assert_equal "#{path}:1: Release day: Thursday.", successful_tool_output(recalled, "memory_grep")
      assert_includes successful_tool_output(recalled, "memory_write"), "Wrote conversation/bob.md"
      assert_equal "Bob confirmed the shared release fact.", owner.memory.read("conversation/bob.md").content
      assert_equal changed.to_h, owner.memory.read(path).to_h
      assert_equal document.public_id, reader.memory.read(path).public_id

      restart_group_runtime(allowed: [101, 102])
      @daemon.await_announced(address: "runner")
      # The shared conversation has nine prior tool answers from Alice and Bob.
      after_restart = memory_policy_prompt([["memory_read", { "path" => path }]],
        reply: "group-fact-after-restart", prior_answers: 9)
      receive(update("policy-group-restart", "@rho_bot\n#{after_restart}", user: 102, chat: -10, topic: 7, mention: true))
      assert_equal reader_id, current("-10:7", user: 102)
      restarted = memory_policy_reply(reader, "group-fact-after-restart")
      assert_includes request_text(restarted), Rho::MemoryPolicy::PROMPT
      assert_equal corrected, successful_tool_output(restarted, "memory_read")
      assert_equal document.public_id, reader.memory.read(path).public_id

      telegram_control("policy-group-new", "/new", user: 101, chat: -10, topic: 7)
      fresh_id = current("-10:7", user: 102)
      refute_equal reader_id, fresh_id
      fresh = @workspace.conversation(fresh_id)
      new_recall = memory_policy_prompt([["memory_read", { "path" => path }]], reply: "group-fact-new-task")
      receive(update("policy-group-new-recall", "@rho_bot\n#{new_recall}", user: 102, chat: -10, topic: 7, mention: true))
      new_turn = memory_policy_reply(fresh, "group-fact-new-task")
      assert_includes request_text(new_turn), Rho::MemoryPolicy::PROMPT
      context = @workspace.runs.run(new_turn.active_variant.run_public_id)
      read = context.fetch.tasks.find { |task| task.tool_name == "memory_read" }
      refute_nil read, "the new task actually tried to read the old path"
      assert read.result.fetch("is_error")
      assert_raises(CybrosAgent::Api::NotFound) { fresh.memory.read(path) }
      assert_predicate owner.fetch, :archived?
      assert_equal document.public_id, owner.memory.read(path).public_id
      assert_equal corrected, owner.memory.read(path).content
      assert_empty @logs
    end

    private

      def memory_policy_prompt(calls, reply:, prior_answers: 0)
        sequence = calls.map { |name, input| "#{name}:#{CGI.escape(JSON.generate(input))}" }
        # Padding is already spent by history, never another actual tool call.
        script = (["memory_ls"] * prior_answers + sequence).join(",")
        "!mock tool_call=#{script} reply=#{CGI.escape(reply)} -- use the confirmed memory facts"
      end

      def memory_policy_reply(chat, answer)
        await("the memory reply #{answer}") do
          tick
          rows = chat.turns.list.items
          failed = rows.find { |turn| turn.status == "failed" }
          flunk "Memory turn failed: #{failed.to_h.inspect}" if failed
          rows.find do |turn|
            turn.kind == "direct_reply" && turn.status == "completed" && turn.active_variant&.content == "Mock: #{answer}"
          end
        end
      end
  end
end
