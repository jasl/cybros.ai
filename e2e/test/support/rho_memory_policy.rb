module E2E
  # Scripted model calls exercise the real memory tools and sealed requests.
  # These journeys prove policy delivery and persistence, not semantic extraction.
  module RhoMemoryPolicy
    def test_the_main_profile_sends_memory_policy_and_saves_a_task_fact_through_model_tools
      boot_runtime(allowed: [101])
      path = "conversation/memory-policy.md"
      content = "Task fact: verified the release checklist.\nSource: #{SecureRandom.hex(6)}.\n"
      prompt = memory_policy_prompt([
        ["memory_ls", { "path" => "conversation/" }],
        ["memory_write", { "path" => path, "content" => content }],
        ["memory_read", { "path" => path }],
      ], reply: "task-fact-saved")
      @runtime.consume(update("policy-main", prompt))
      chat = @workspace.conversation(current("101:0"))
      turn = memory_policy_reply(chat, "task-fact-saved")

      assert_includes request_text(turn), Rho::MemoryPolicy::PROMPT
      assert_includes successful_tool_output(turn, "memory_ls"), "No memory documents."
      assert_includes successful_tool_output(turn, "memory_write"), "Wrote #{path}"
      assert_equal content, successful_tool_output(turn, "memory_read")
      assert_equal content, chat.memory.read(path).content
      assert_empty @logs
    end

    def test_group_model_memory_is_corrected_shared_and_read_after_restart_and_new_task
      boot_runtime(allowed: [101, 102])
      path = "group/team.md"
      original = "Release day: Tuesday.\nKeep: blue marker #{SecureRandom.hex(6)}.\n"
      corrected = original.sub("Tuesday", "Thursday")
      prompt = memory_policy_prompt([
        ["memory_ls", { "path" => "group/" }],
        ["memory_write", { "path" => path, "content" => original }],
        ["memory_read", { "path" => path }],
      ], reply: "group-fact-saved")
      @runtime.consume(update("policy-group-save", "@rho_bot\n#{prompt}", chat: -10, topic: 7, mention: true))
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
        ["memory_grep", { "pattern" => "Release day:", "path" => "group/" }],
      ], reply: "group-fact-corrected", prior_answers: 3)
      @runtime.consume(update("policy-group-correct", "@rho_bot\n#{correction}", chat: -10, topic: 7, mention: true))
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
        ["memory_grep", { "pattern" => "Release day:", "path" => "group/" }],
        ["memory_write", { "path" => path, "content" => "must not replace shared knowledge" }],
      ], reply: "group-fact-recalled")
      @runtime.consume(update("policy-group-recall", "@rho_bot\n#{recall}", user: 102, chat: -10, topic: 7, mention: true))
      reader_id = current("-10:7", user: 102)
      refute_equal owner_id, reader_id
      reader = @workspace.conversation(reader_id)
      recalled = memory_policy_reply(reader, "group-fact-recalled")
      assert_includes request_text(recalled), Rho::MemoryPolicy::PROMPT
      assert_equal corrected, successful_tool_output(recalled, "memory_read")
      assert_equal "#{path}:1: Release day: Thursday.", successful_tool_output(recalled, "memory_grep")
      assert_memory_policy_write_refused(recalled)
      assert_equal changed.to_h, owner.memory.read(path).to_h
      assert_equal document.public_id, reader.memory.read(path).public_id

      restart_group_runtime(allowed: [101, 102])
      @daemon.await_announced(address: "runner")
      # This reader's history has read, grep and the refused write: three answers.
      after_restart = memory_policy_prompt([["memory_read", { "path" => path }]],
        reply: "group-fact-after-restart", prior_answers: 3)
      @runtime.consume(update("policy-group-restart", "@rho_bot\n#{after_restart}", user: 102, chat: -10, topic: 7, mention: true))
      assert_equal reader_id, current("-10:7", user: 102)
      restarted = memory_policy_reply(reader, "group-fact-after-restart")
      assert_includes request_text(restarted), Rho::MemoryPolicy::PROMPT
      assert_equal corrected, successful_tool_output(restarted, "memory_read")
      assert_equal document.public_id, reader.memory.read(path).public_id

      telegram_control("policy-group-new", "/new", user: 102, chat: -10, topic: 7)
      fresh_id = current("-10:7", user: 102)
      refute_equal reader_id, fresh_id
      fresh = @workspace.conversation(fresh_id)
      new_recall = memory_policy_prompt([["memory_read", { "path" => path }]], reply: "group-fact-new-task")
      @runtime.consume(update("policy-group-new-recall", "@rho_bot\n#{new_recall}", user: 102, chat: -10, topic: 7, mention: true))
      new_turn = memory_policy_reply(fresh, "group-fact-new-task")
      assert_includes request_text(new_turn), Rho::MemoryPolicy::PROMPT
      assert_equal corrected, successful_tool_output(new_turn, "memory_read")
      assert_equal document.public_id, fresh.memory.read(path).public_id
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

      def assert_memory_policy_write_refused(turn)
        context = @workspace.agent_loops.agent_loop(turn.active_variant.agent_loop_public_id)
        writes = context.fetch.tasks.select { |task| task.tool_name == "memory_write" }
        assert_equal 1, writes.length, "the model must actually attempt the read-only write"
        task = writes.fetch(0)
        assert_equal "completed", task.status
        assert task.result.fetch("is_error"), task.to_h.inspect
        assert_match(/\Amemory_read_only:/, context.task(task.key).output)
      end
  end
end
