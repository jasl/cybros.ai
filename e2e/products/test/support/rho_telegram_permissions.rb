module E2E
  # An allowed Telegram sender can ask the model for an effect; admission must
  # still exclude it before any runner or browser claims the call. The owner
  # control proves these are installed tools; the external Bot admits kernel tools only.
  module RhoTelegramPermissions
    def test_external_telegram_tool_authority_excludes_runner_tools_in_groups_and_private_chats
      boot_runtime(allowed: [101, 102, 103])
      @telegram.provide_member(-10, 101, status: "member")
      @telegram.provide_member(-10, 103, status: "administrator")
      File.write(permission_path("protected.txt"), "original contents\n")
      owner_prompt = permission_prompt([["write", { "path" => "owner.txt", "content" => "owner works" }]])
      receive(update("permission-owner", owner_prompt))
      owner = completed_reply(@workspace.conversation(current("101:0")))
      assert_includes successful_tool_output(owner, "write"), "owner.txt"
      assert_equal "owner works", File.read(permission_path("owner.txt"))
      installed = permission_context(owner).task("r1").tool_definitions
        .map { |entry| entry.dig("route", "tool_name") || entry.dig("function", "name") }
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
        receive(incoming)
        chat = @workspace.conversation(current("#{source.fetch(:chat)}:#{source.fetch(:topic, 0)}", user: source.fetch(:user)))
        reply = completed_reply(chat)
        context = permission_context(reply)
        assert_permission_calls_denied(context, ["read", *effects])
        assert_permission_rounds_external(context)
        assert_equal "original contents\n", File.read(permission_path("protected.txt"))
        refute File.exist?(permission_path("forbidden.txt"))
        refute File.exist?(permission_path("process-effect.txt"))
        assert_empty @daemon.control(:get, "/processes").fetch("processes")
      end

      assert_match(/owner/i, telegram_control("permission-admin-access", "/access users add 104", user: 103, chat: -10, topic: 7))
      assert_match(/owner/i, telegram_control("permission-admin-observe", "/observe on", user: 103, chat: -10, topic: 7))
      assert_empty @logs
    end

    def test_external_telegram_delegation_and_background_mail_keep_the_source_tool_set
      boot_runtime(allowed: [101, 102])
      telegram_control("delegate-new", "/new", chat: -10, topic: 7)
      chat = @workspace.conversation(current("-10:7"))
      write = ["write", { "path" => "delegated-forbidden.txt", "content" => "forbidden" }]
      # A child speaks a new mock marker into its result. The callback attempts
      # a second write, so both captured executions must preserve the Bot floor.
      callback = "delegated result\n#{permission_prompt([write], reply: "callback-finished", prior_answers: 2)}"
      child = permission_prompt([["memory_ls", {}], write], reply: callback)
      arguments = { "prompt" => child, "lifetime" => "conversation" }
      prompt = permission_prompt([["delegate_task", arguments], ["ask", { "prompt" => "Finish this foreground reply?" }]], reply: "launched")
      receive(permission_update("delegate-launch", prompt, user: 102, chat: -10, topic: 7))
      question_id, question = await("the delegated foreground ask") do
        tick
        @state.read.fetch("questions").find { |_id, row| row["conversation_id"] == chat.public_id && row["kind"] == "ask" }
      end
      context = @workspace.runs.run(question.fetch("run_public_id"))
      await("the delegated child attempts its forbidden write") do
        context.fetch.tasks.find { |task| task.tool_name == "write" && task.status == "failed" }
      end
      assert_empty chat.events(limit: 100).select { |event| event.type == "input_accepted" && event.payload["origin"] == "task_result" }
      assert_equal @state.read.fetch("speakers").fetch("102"), question.fetch("requester_speaker_public_id")
      assert_includes telegram_control("delegate-answer", "/answer #{question_id} Continue", user: 102, chat: -10, topic: 7), "Response accepted."
      assert_equal "completed", context.fetch.tasks.find(&:await?).status
      replies = permission_replies(chat, count: 2)
      assert_equal "Mock: launched", replies.first.active_variant.content
      assert_equal "Mock: callback-finished", replies.last.active_variant.content
      assert_permission_calls_denied(context, ["write"])
      assert_permission_rounds_external(context)
      reads = context.fetch.tasks.select { |task| task.tool_name == "memory_ls" }
      assert_equal 1, reads.length
      assert_equal "completed", reads.first.status
      assert context.fetch.tasks.any? { |task| task.kind == "model_task" && task.lifetime == "conversation" }
      callback_context = permission_context(replies.last)
      assert_permission_calls_denied(callback_context, ["write"])
      assert_permission_rounds_external(callback_context)
      receipts = chat.events(limit: 100).select { |event| event.type == "input_accepted" && event.payload["origin"] == "task_result" }
      assert_equal 1, receipts.length
      assert_equal question.fetch("run_public_id"), receipts.first.payload.fetch("run_public_id")
      refute File.exist?(permission_path("delegated-forbidden.txt"))
      await("the supplementary external answer reaches the source topic") do
        tick
        @telegram.formal(-10).any? { |_method, params| params[:text] == "Mock: callback-finished" }
      end
      deliveries = @telegram.formal(-10).select { |_method, params| params[:text] == "Mock: callback-finished" }
      assert_equal 1, deliveries.length
      assert_equal 7, deliveries.first.last.fetch(:message_thread_id)

      @core.ensure_bot_current(agent_public_id: bot_id_for("102:0"), operation_id: "direct-code-current")
      script = "return await nexus.steps([{tool: {key: 'forbidden', name: 'write', route: #{JSON.generate(telegram_runner_route)}, " \
        "input: {path: 'code-direct.txt', content: 'forbidden'}}}]);"
      receive(update("direct-code", permission_prompt([["code", { "code" => script }]]), user: 102, chat: 102))
      reply = completed_reply(@workspace.conversation(current("102:0")))
      context = permission_context(reply)
      assert_permission_calls_denied(context, ["code"])
      assert_empty context.fetch.tasks.select { |task| task.tool_name == "write" }
      refute File.exist?(permission_path("code-direct.txt"))
      assert_permission_rounds_external(context)
      assert_empty @logs
    ensure
      stop_group_work(chat)
    end

    def test_nonowner_telegram_queue_replay_restart_and_owner_steer_do_not_widen_tools
      boot_runtime(allowed: [101, 102])
      chat, running, question_id, source = telegram_held_parent("readonly-held", user: 102, chat: -10, topic: 7)
      forbidden = ["write", { "path" => "steered.txt", "content" => "forbidden" }]
      queued = permission_prompt([forbidden], reply: "queued-original", prior_answers: 2)
      incoming = permission_update("readonly-lost-ack", queued, user: 102, chat: -10, topic: 7)
      @bridge.lose_next_ack = true
      receive(incoming)
      assert @state.read.fetch("pending_inputs").values.find { |row| row.fetch("update_id") == incoming.fetch("update_id") }.fetch("submission")
      assert_nil @state.read["pending_update"], "the source is durable before Telegram advances its offset"
      assert_equal "Rho::ConnectionError", @logs.pop.last.fetch(:reason)
      queued_id = chat.inputs.list.items.fetch(0).public_id
      restart_group_runtime(allowed: [101, 102])
      receive(incoming)
      receive(incoming)
      assert_equal [queued_id], chat.inputs.list.items.map(&:public_id)
      input = @core.inputs(chat.public_id).fetch(0)
      captured_names = permission_context(running).task("r1").tool_definitions.map do |entry|
        entry["name"] || entry.fetch("function").fetch("name")
      end
      assert_equal captured_names.sort, input.fetch("tool_names").sort,
        "replayed queued input retains the Bot's captured tool floor"
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
        assert_permission_rounds_external(context)
      end
      assert_equal 3, chat.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_empty chat.inputs.list.items
      refute File.exist?(permission_path("steered.txt"))
      assert_empty @logs
    ensure
      stop_group_work(chat)
    end

    module Helpers
      private

        def permission_path(name) = File.join(@root, "project", name)
        def permission_context(turn) = @workspace.runs.run(turn.active_variant.run_public_id)

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

        def assert_permission_rounds_external(context)
          rounds = context.fetch.tasks.select(&:model_task?)
          refute_empty rounds
          catalog = @client.tools.list.to_h { |entry| [entry.name, entry.canonical_name] }
          rounds.each do |round|
            definitions = context.task(round.key).tool_definitions
            refute_nil definitions, "#{round.key} must expose its actual frozen tools"
            assert_empty definitions.filter_map { |entry| entry["route"] }, "external work has no Runner or custom provider routes"
            definitions.each do |entry|
              name = entry["name"] || entry.fetch("function").fetch("name")
              canonical = entry["canonical"] || catalog.fetch(name)
              assert_includes Rho::BotPolicy::KERNEL_TOOLS, canonical, "#{round.key} froze an external capability outside the Bot floor"
            end
            permitted_names = definitions.map { |entry| entry["name"] || entry.fetch("function").fetch("name") }
            names = permission_tools(context.tasks_context(round.key).request)
            assert_empty names - permitted_names, "#{round.key} regained undeclared tools: #{names.inspect}"
          end
          assert_includes context.task("r1").tool_definitions.map { |entry| entry.fetch("function").fetch("name") }, "memory_read"
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

    include Helpers
  end
end
