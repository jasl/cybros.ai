module E2E
  # An allowed Telegram sender can ask the model for an effect; admission must
  # still exclude it before any runner or browser claims the call. The owner
  # control below proves these are installed tools, not unavailable fixtures.
  module RhoTelegramPermissions
    def test_nonowner_telegram_tool_authority_is_read_only_in_groups_and_private_chats
      boot_runtime(allowed: [101, 102, 103])
      @telegram.provide_member(-10, 101, status: "member")
      @telegram.provide_member(-10, 103, status: "administrator")
      File.write(permission_path("protected.txt"), "original contents\n")
      owner_prompt = permission_prompt([["write", { "path" => "owner.txt", "content" => "owner works" }]])
      @runtime.consume(update("permission-owner", owner_prompt))
      owner = completed_reply(@workspace.conversation(current("101:0")))
      assert_includes successful_tool_output(owner, "write"), "owner.txt"
      assert_equal "owner works", File.read(permission_path("owner.txt"))
      installed = permission_tools(permission_context(owner).tasks_context("r1").request)
      effects = %w[write edit bash start_process stop_process browser_navigate browser_click browser_type browser_evaluate]
      effects.each { |name| assert_includes installed, name }

      calls = [
        ["read", { "path" => "protected.txt" }],
        ["write", { "path" => "forbidden.txt", "content" => "forbidden" }],
        ["edit", { "path" => "protected.txt", "edits" => [{ "oldText" => "original", "newText" => "changed" }] }],
        ["bash", { "command" => "rm -- protected.txt" }],
        ["start_process", { "command" => "printf forbidden > process-effect.txt", "wait_seconds" => 0 }],
        ["stop_process", { "id" => "p1" }],
        ["browser_navigate", { "url" => "about:blank" }],
        ["browser_click", { "ref" => "e1" }],
        ["browser_type", { "ref" => "e1", "text" => "forbidden" }],
        ["browser_evaluate", { "expression" => "document.body.textContent = 'forbidden'" }],
      ]
      [{ user: 102, chat: 102 }, { user: 103, chat: -10, topic: 7 }].each do |source|
        incoming = permission_update(["permission-matrix", source.fetch(:user)], permission_prompt(calls), **source)
        @runtime.consume(incoming)
        chat = @workspace.conversation(current("#{source.fetch(:chat)}:#{source.fetch(:topic, 0)}", user: source.fetch(:user)))
        reply = completed_reply(chat)
        assert_includes successful_tool_output(reply, "read"), "original contents"
        context = permission_context(reply)
        assert_permission_calls_denied(context, effects)
        assert_permission_rounds_read_only(context)
        assert_equal "original contents\n", File.read(permission_path("protected.txt"))
        refute File.exist?(permission_path("forbidden.txt"))
        refute File.exist?(permission_path("process-effect.txt"))
        assert_empty @daemon.control(:get, "/processes").fetch("processes")
      end

      assert_match(/owner/i, telegram_control("permission-admin-access", "/access users add 104", user: 103, chat: -10, topic: 7))
      assert_match(/owner/i, telegram_control("permission-admin-observe", "/observe on", user: 103, chat: -10, topic: 7))
      assert_empty @logs
    end

    def test_nonowner_telegram_task_compose_and_background_mail_keep_the_source_tool_set
      boot_runtime(allowed: [101, 102])
      File.write(permission_path("delegated.txt"), "readable delegated evidence\n")
      %w[task compose].each do |delegation|
        telegram_control([delegation, "new"], "/new", user: 102, chat: -10, topic: 7)
        chat = @workspace.conversation(current("-10:7", user: 102))
        forbidden = "#{delegation}-forbidden.txt"
        write = ["write", { "path" => forbidden, "content" => "forbidden" }]
        # A child speaks a new mock marker into its result. When that result is
        # mailed, the callback really attempts another write, under its own r1.
        callback = "delegated result\n#{permission_prompt([write], reply: "callback-finished", prior_answers: 2)}"
        child = permission_prompt([["read", { "path" => "delegated.txt" }], write], reply: callback)
        arguments = if delegation == "task"
          { "prompt" => child, "lifetime" => "conversation" }
        else
          { "script" => "g.model({key: 'readonly_child', prompt: #{JSON.generate(child)}});" }
        end
        prompt = permission_prompt([[delegation, arguments], ["ask", { "prompt" => "Finish this foreground reply?" }]], reply: "launched")
        incoming = permission_update([delegation, "launch"], prompt, user: 102, chat: -10, topic: 7)
        @runtime.consume(incoming)
        question_id, question = await("the delegated foreground ask") do
          tick
          @state.read.fetch("questions").find { |_id, row| row["conversation_id"] == chat.public_id && row["kind"] == "ask" }
        end
        context = @workspace.agent_loops.agent_loop(question.fetch("loop_public_id"))
        await("the delegated child attempts its forbidden write") do
          context.fetch.tasks.find { |task| task.tool_name == "write" && task.status == "failed" }
        end
        assert_empty chat.events(limit: 100).select { |event| event.type == "input_accepted" && event.payload["origin"] == "task_result" }
        telegram_control([delegation, "answer"], "/answer #{question_id} Continue", user: 102, chat: -10, topic: 7)
        assert_equal "completed", context.fetch.tasks.find(&:await?).status
        replies = permission_replies(chat, count: 2)
        assert_equal "Mock: launched", replies.first.active_variant.content
        assert_equal "Mock: callback-finished", replies.last.active_variant.content
        assert_permission_calls_denied(context, ["write"])
        assert_permission_rounds_read_only(context)
        reads = context.fetch.tasks.select { |task| task.tool_name == "read" }
        assert_equal 1, reads.length
        assert_equal "completed", reads.first.status
        assert_includes context.task(reads.first.key).output, "readable delegated evidence"
        assert context.fetch.tasks.any? { |task| task.kind == "model_task" && task.lifetime == "conversation" }
        callback_context = permission_context(replies.last)
        assert_permission_calls_denied(callback_context, ["write"])
        assert_permission_rounds_read_only(callback_context)
        receipts = chat.events(limit: 100).select { |event| event.type == "input_accepted" && event.payload["origin"] == "task_result" }
        assert_equal 1, receipts.length
        assert_equal question.fetch("loop_public_id"), receipts.first.payload.fetch("agent_loop_public_id")
        refute File.exist?(permission_path(forbidden))
        await("the supplementary read-only answer reaches the source topic") do
          tick
          @telegram.formal(-10).count { |_method, params| params[:text] == "Mock: callback-finished" } == (%w[task compose].index(delegation) + 1)
        end
        deliveries = @telegram.formal(-10).select { |_method, params| params[:text] == "Mock: callback-finished" }
        assert deliveries.all? { |_method, params| params[:message_thread_id] == 7 }
      end

      telegram_control("direct-compose-new", "/new", user: 102, chat: 102)
      script = "g.tool({key: 'forbidden', name: 'write', input: {path: 'compose-direct.txt', content: 'forbidden'}});"
      @runtime.consume(update("direct-compose", permission_prompt([["compose", { "script" => script }]]), user: 102, chat: 102))
      reply = completed_reply(@workspace.conversation(current("102:0")))
      context = permission_context(reply)
      calls = context.fetch.tasks.select { |task| task.tool_name == "compose" }
      assert_equal 1, calls.length
      refused = calls.first
      assert_equal "completed", refused.status
      assert refused.result.fetch("is_error")
      assert_match(/\Aunknown_tool_name:/, context.task(refused.key).output)
      assert_empty context.fetch.tasks.select { |task| task.tool_name == "write" }
      refute File.exist?(permission_path("compose-direct.txt"))
      assert_permission_rounds_read_only(context)
      assert_empty @logs
    end

    def test_nonowner_telegram_queue_replay_restart_and_owner_steer_do_not_widen_tools
      boot_runtime(allowed: [101, 102])
      chat, running, question_id, source = telegram_held_parent("readonly-held", user: 102, chat: -10, topic: 7)
      forbidden = ["write", { "path" => "steered.txt", "content" => "forbidden" }]
      queued = permission_prompt([forbidden], reply: "queued-original", prior_answers: 2)
      incoming = permission_update("readonly-lost-ack", queued, user: 102, chat: -10, topic: 7)
      @bridge.lose_next_ack = true
      assert_raises(Rho::ConnectionError) { @runtime.consume(incoming) }
      queued_id = chat.inputs.list.items.fetch(0).public_id
      restart_group_runtime(allowed: [101, 102])
      @runtime.consume(incoming)
      @runtime.consume(incoming)
      assert_equal [queued_id], chat.inputs.list.items.map(&:public_id)
      input = @core.inputs(chat.public_id).fetch(0)
      assert_includes input.fetch("tool_names"), "read"
      refute_includes input.fetch("tool_names"), "write"
      assert_includes telegram_control("readonly-list", "/queue", user: 102, chat: -10, topic: 7), queued_id
      edited = permission_prompt([forbidden], reply: "queued-edited", prior_answers: 2)
      assert_includes telegram_control("readonly-edit", "/queue edit 1 #{edited}", user: 102, chat: -10, topic: 7), "updated", "Admitted input: #{input.inspect}"
      assert_equal [edited], chat.inputs.list.items.map(&:text)

      steer = permission_prompt([forbidden], reply: "owner-steered", prior_answers: 1)
      assert_includes telegram_control("readonly-owner-steer", "/steer #{steer}", chat: -10, topic: 7, reply_to: source), "instruction is accepted"
      telegram_control("readonly-owner-answer", "/answer #{question_id} Continue", chat: -10, topic: 7)
      assert_equal "completed", telegram_question_task(running).status
      replies = permission_replies(chat, count: 2)
      assert_equal ["Mock: owner-steered", "Mock: queued-edited"], replies.map { |turn| turn.active_variant.content }
      assert_equal running.public_id, replies.first.public_id
      replies.each do |turn|
        context = permission_context(turn)
        assert_permission_calls_denied(context, ["write"])
        assert_permission_rounds_read_only(context)
      end
      assert_equal 3, chat.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_empty chat.inputs.list.items
      refute File.exist?(permission_path("steered.txt"))
      assert_empty @logs
    ensure
      stop_group_work(chat)
    end

    def test_nonowner_telegram_cannot_continue_older_broad_work_but_can_cancel_it
      boot_runtime(allowed: [101, 102])
      # A real owner configuration accepts wide work; after owner rotation the
      # same allowed sender must not resume those already durable broad rights.
      boot_runtime(allowed: [101, 102], owner_id: 102)
      chat, running, question_id = telegram_held_parent("legacy-held", user: 102, chat: 102)
      assert_includes permission_tools(permission_context(running).tasks_context("r1").request), "write"
      queued = "!mock reply=old-wide-input -- an already admitted broad request"
      @runtime.consume(update("legacy-queued", queued, user: 102, chat: 102))
      old_input = chat.inputs.list.items.fetch(0).public_id
      restart_group_runtime(allowed: [101, 102])
      assert_match(/read-only/, telegram_control("legacy-steer", "/steer Continue", user: 102, chat: 102))
      assert_match(/read-only/, telegram_control("legacy-answer", "/answer #{question_id} Continue", user: 102, chat: 102))
      assert_equal "awaiting_input", telegram_question_task(running).status
      assert_includes telegram_control("legacy-list", "/queue", user: 102, chat: 102), old_input
      assert_match(/read-only/, telegram_control("legacy-edit", "/queue edit 1 changed", user: 102, chat: 102))
      assert_equal [queued], chat.inputs.list.items.map(&:text)
      assert_includes telegram_control("legacy-cancel", "/queue cancel 1", user: 102, chat: 102), "canceled"
      assert_empty chat.inputs.list.items
      assert_includes telegram_control("legacy-stop", "/stop", user: 102, chat: 102), "Stop requested"
      await_group_turn_status(chat, running, "canceled")
      telegram_control("legacy-new", "/new", user: 102, chat: 102)
      @runtime.consume(update("legacy-fresh", "!mock reply=fresh-read-only -- a fresh request", user: 102, chat: 102))
      reply = completed_reply(@workspace.conversation(current("102:0")))
      assert_permission_rounds_read_only(permission_context(reply))
      assert_empty @logs
    ensure
      stop_group_work(chat)
    end

    def test_nonowner_telegram_side_and_its_followup_have_no_tools
      boot_runtime(allowed: [101, 102])
      @runtime.consume(update("readonly-side-parent", "!mock reply=parent -- context", user: 102, chat: 102))
      parent_id = current("102:0")
      parent = @workspace.conversation(parent_id)
      completed_reply(parent)
      write = ["write", { "path" => "side-effect.txt", "content" => "forbidden" }]
      @runtime.consume(update("readonly-side", "/btw #{permission_prompt([write], reply: "side-first")}", user: 102, chat: 102))
      side = @workspace.conversation(telegram_side_id("102:0", parent_id, user: 102))
      first = permission_replies(side, count: 1).first
      assert_permission_no_tools(permission_context(first))
      delivery_id = await("the read-only side's first Telegram answer") do
        tick
        @telegram.messages.find { |_id, params| params[:chat_id] == "102" && params[:text] == "Side answer:\nMock: side-first" }&.first
      end
      incoming = update("readonly-side-followup", permission_prompt([write], reply: "side-followup"), user: 102, chat: 102)
      incoming.fetch("message")["reply_to_message"] = { "message_id" => delivery_id, "from" => @bot.merge("is_bot" => true) }
      @runtime.consume(incoming)
      replies = permission_replies(side, count: 2)
      assert_equal "Mock: side-followup", replies.last.active_variant.content
      assert_permission_no_tools(permission_context(replies.last))
      assert_equal parent_id, current("102:0")
      assert_equal 1, parent.turns.list.items.count { |turn| turn.kind == "direct_reply" }
      refute File.exist?(permission_path("side-effect.txt"))
      assert_empty @logs
    end

    private

      def permission_path(name) = File.join(@root, "project", name)
      def permission_context(turn) = @workspace.agent_loops.agent_loop(turn.active_variant.agent_loop_public_id)

      def permission_prompt(calls, reply: "checked", prior_answers: 0)
        group = calls.map { |name, input| "#{name}:#{CGI.escape(JSON.generate(input))}" }.join("&")
        # This stateless provider advances by function answers in the whole
        # request. Pad preceding answers; each actual new call remains real.
        script = (["read:#{CGI.escape(JSON.generate("path" => "unused-padding"))}"] * prior_answers + [group]).join(",")
        "!mock tool_call=#{script} reply=#{CGI.escape(reply)} -- exercise the admitted operation set"
      end

      def permission_update(id, prompt, user:, chat:, topic: nil)
        text = chat.negative? ? "@rho_bot\n#{prompt}" : prompt
        update(id, text, user: user, chat: chat, topic: topic, mention: chat.negative?)
      end

      def permission_replies(chat, count:)
        await("#{count} completed permission replies") do
          tick
          rows = chat.turns.list.items.reject(&:inherited).select { |turn| turn.kind == "direct_reply" }
          failed = rows.find { |turn| turn.status == "failed" }
          flunk "Permission turn failed: #{failed.to_h.inspect}" if failed
          completed = rows.select { |turn| turn.status == "completed" }
          completed if completed.length == count
        end
      end

      def permission_tools(request)
        return [] if request.request_options["tool_choice"] == "none"

        Array(request.request_options["tools"]).map { |entry| entry["name"] || entry.fetch("function").fetch("name") }
      end

      def assert_permission_rounds_read_only(context)
        rounds = context.fetch.tasks.select(&:round?)
        refute_empty rounds
        # Attachment staging/publication and explicitly bound database notes are
        # available; writes to working files and process/browser effects are not.
        allowed = %w[read ls find grep file_import file_publish web_fetch task compose wait ask Agent AskUserQuestion Workflow
          memory_read memory_write memory_edit memory_ls memory_grep memory_delete]
        rounds.each do |round|
          definitions = context.task(round.key).tool_definitions
          refute_nil definitions, "#{round.key} must expose its actual frozen tools"
          frozen_names = definitions.map { |entry| entry["name"] || entry.fetch("function").fetch("name") }
          assert_empty frozen_names - allowed, "#{round.key} froze effects: #{frozen_names.inspect}"
          names = permission_tools(context.tasks_context(round.key).request)
          assert_empty names - allowed, "#{round.key} regained effects: #{names.inspect}"
        end
        assert_includes permission_tools(context.tasks_context("r1").request), "read"
      end

      def assert_permission_no_tools(context)
        rounds = context.fetch.tasks.select(&:round?)
        refute_empty rounds
        rounds.each do |round|
          assert_equal [], context.task(round.key).tool_definitions
          assert_empty permission_tools(context.tasks_context(round.key).request)
        end
      end

      def assert_permission_calls_denied(context, names)
        names.each do |name|
          calls = context.fetch.tasks.select { |task| task.tool_name == name }
          assert_equal 1, calls.length, "#{name} must actually be attempted: #{context.fetch.tasks.map(&:to_h).inspect}"
          assert_equal "failed", calls.first.status
          assert_equal "unknown_tool", calls.first.error.fetch("key")
          assert_nil calls.first.claimed_by, "#{name} must be rejected before any executor claims it"
        end
      end
  end
end
