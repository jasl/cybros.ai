module E2E
  # Telegram updates cross the real Core, daemon and Nexus input lane. An ask
  # keeps the parent at a model boundary until this journey answers it.
  module RhoTelegramCommands
    def test_telegram_steer_joins_the_running_turn_while_an_ordinary_message_waits
      boot_runtime(allowed: [101])
      chat, running, question_id = telegram_held_parent(1)
      loop_id = running.active_variant.agent_loop_public_id

      queued_text = "!mock reply=queued-answer -- answer in the next turn"
      @runtime.consume(update(2, queued_text))
      steer_text = "!mock reply=steered-answer -- use the revised instruction now"
      steering_update = update(3, "/steer #{steer_text}")
      @runtime.consume(steering_update)
      @runtime.consume(steering_update)
      inputs = chat.inputs.list.items
      assert_equal [queued_text, steer_text], inputs.map(&:text)
      assert_equal %w[queue steer], inputs.map(&:delivery_mode)
      assert_equal %w[pending steering], inputs.map(&:state)
      assert_equal 1, chat.turns.list.items.count { |turn| turn.kind == "direct_reply" }
      assert_equal "awaiting_input", telegram_question_task(running).status

      @runtime.consume(update(4, "/answer #{question_id} Continue"))
      replies = await("the steered answer and the queued turn") do
        tick
        rows = chat.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
        rows if rows.length == 2
      end
      assert_equal ["Mock: steered-answer", "Mock: queued-answer"], replies.map { |turn| turn.active_variant.content }
      assert_equal running.public_id, replies.first.public_id
      assert_equal loop_id, replies.first.active_variant.agent_loop_public_id
      refute_equal loop_id, replies.last.active_variant.agent_loop_public_id

      events = chat.events(limit: 100).items
      landed = events.find do |event|
        event.type == "input_materialized" && event.payload["input_public_id"] == inputs.last.public_id
      end
      refute_nil landed
      assert_equal running.public_id, landed.payload.fetch("turn_public_id")
      assert_equal loop_id, landed.payload.fetch("agent_loop_public_id")
      refute_equal "r1", landed.payload.fetch("task_key")
      request = @workspace.agent_loops.agent_loop(loop_id).tasks_context(landed.payload.fetch("task_key")).request
      material = telegram_request_text(request)
      assert_includes material, "use the revised instruction now"
      refute_includes material, "/steer"
      refute_includes material, "answer in the next turn"
      settled = events.find do |event|
        event.type == "turn_status" && event.payload["turn_public_id"] == running.public_id && event.payload["status"] == "completed"
      end
      drained = events.find do |event|
        event.type == "input_materialized" && event.payload["input_public_id"] == inputs.first.public_id
      end
      refute_nil settled
      refute_nil drained
      assert_operator settled.sequence, :<, drained.sequence
      assert_equal replies.last.public_id, drained.payload.fetch("turn_public_id")
      assert_empty chat.inputs.list.items
      await("both answers reach the original Telegram chat") { tick; @telegram.formal(101).length == 2 }
      assert_equal ["Mock: steered-answer", "Mock: queued-answer"], @telegram.formal(101).map { |_method, params| params.fetch(:text) }
      assert_empty @logs
    end

    def test_telegram_btw_preserves_group_context_denies_tools_and_replays_once_beside_the_parent
      marker = "private-side-note-#{SecureRandom.hex(6)}"
      @memory << @human.profile.memory.write("user/#{marker}.md", marker,
        expected_public_id: nil, expected_lock_version: nil)
      boot_runtime(allowed: [101, 102])
      @runtime.consume(update(1, "@rho_bot\n!mock reply=group-prefix -- shared topic premise", chat: -10, topic: 7, mention: true))
      parent_id = current("-10:7")
      chat = @workspace.conversation(parent_id)
      prefix = completed_reply(chat)
      await("the group's initial answer") { tick; @telegram.formal(-10).length == 1 }
      held_chat, running, question_id = telegram_held_parent(2, chat: -10, topic: 7)
      assert_equal chat.public_id, held_chat.public_id
      before = chat.events(limit: 100).count { |event| event.type == "input_accepted" }

      # `none` keeps the parent's tool declarations for prefix reuse; the real
      # daemon must deny the call before it can reach the runner.
      filename = "telegram-side-must-not-exist.txt"
      arguments = CGI.escape(JSON.generate("command" => "printf forbidden > #{filename}"))
      incoming = update(3, "/btw !mock tool_call=bash:#{arguments} reply=side-answer -- explain the shared topic",
        chat: -10, topic: 7)
      @bridge.lose_next_ack = true
      assert_raises(Rho::ConnectionError) { @runtime.consume(incoming) }
      @runtime.consume(incoming)
      @runtime.consume(incoming)
      side_id = telegram_side_id("-10:7", parent_id)
      side = @workspace.conversation(side_id)
      side_reply = await("the group's independent side answer") do
        tick
        side.turns.list.items.find { |turn| !turn.inherited && turn.kind == "direct_reply" && turn.status == "completed" }
      end
      assert_predicate side.fetch, :side?
      assert_equal prefix.speaker.user_public_id, side_reply.speaker.user_public_id
      assert_equal chat.fetch.answering_user_public_id, side.fetch.answering_user_public_id
      assert_equal 1, side.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_equal before, chat.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_equal parent_id, current("-10:7")
      assert_equal "awaiting_input", telegram_question_task(running).status

      request = side.turns.request(side_reply.public_id, side_reply.active_variant.public_id)
      material = telegram_request_text(request)
      assert_includes material, "shared topic premise"
      assert_includes material, "explain the shared topic"
      refute_includes material, marker
      refute_includes material, "/btw"
      names = Array(request.request_options["tools"]).map { |tool| tool["name"] || tool.dig("function", "name") }
      assert_includes names, "bash"
      assert_equal %w[memory_delete memory_edit memory_grep memory_ls memory_read memory_write], names.grep(/\Amemory_/).sort
      refute names.any? { |name| name.start_with?("skill_", "conversation_") }
      side_loop = @workspace.agent_loops.agent_loop(side_reply.active_variant.agent_loop_public_id).fetch
      calls = side_loop.tasks.select { |task| task.kind == "tool_task" }
      assert_equal 1, calls.length
      assert_equal "bash", calls.first.tool_name
      assert_equal "failed", calls.first.status
      assert_equal "approval_denied", calls.first.error.fetch("key")
      assert_equal "agent", calls.first.approval.fetch("origin")
      refute File.exist?(File.join(@root, "project", filename)), "the side's tool must never execute"

      await("the labeled side answer returns to the same topic before the parent") do
        tick
        @telegram.formal(-10).any? { |_method, params| params[:text] == "Side answer:\nMock: side-answer" }
      end
      side_delivery = @telegram.formal(-10).find { |_method, params| params[:text] == "Side answer:\nMock: side-answer" }.last
      assert_equal 7, side_delivery.fetch(:message_thread_id)
      formal_texts = @telegram.formal(-10).map { |_method, params| params.fetch(:text) }
      assert_equal 2, formal_texts.length, "formal replies: #{formal_texts.inspect}"
      assert_equal 1, formal_texts.count("Mock: group-prefix"), "formal replies: #{formal_texts.inspect}"
      side_texts = formal_texts.select { |text| text.start_with?("Side answer:\n") }
      refute_includes side_texts.join("\n"), "group-prefix"
      telegram_control("group-side-parent-answer", "/answer #{question_id} Continue", chat: -10, topic: 7)
      await("the original group answer still completes") do
        tick
        chat.turns.list.items.any? { |turn| turn.public_id == running.public_id && turn.status == "completed" }
      end
      assert_equal parent_id, current("-10:7")
      assert_empty @logs
    end

    def test_telegram_stop_targets_the_parent_or_replied_side_without_touching_other_work
      boot_runtime(allowed: [101])
      old_chat, old_turn, = telegram_held_parent(1)
      old_side, old_side_turn = telegram_streaming_side(2, old_chat.public_id, "earlier-side")
      @runtime.consume(update(3, "/new"))
      chat, running, = telegram_held_parent(4)
      side, side_turn, side_source = telegram_streaming_side(5, chat.public_id, "current-side")
      refute_equal old_chat.public_id, chat.public_id
      refute_equal old_side.public_id, side.public_id
      assert_equal chat.public_id, current("101:0")

      parent_stop = update(6, "/stop")
      @bridge.lose_next_stop_ack = true
      assert_raises(Rho::ConnectionError) { @runtime.consume(parent_stop) }
      boot_runtime(allowed: [101])
      @runtime.consume(parent_stop)
      @runtime.consume(parent_stop)
      assert_equal [running.active_variant.agent_loop_public_id], @bridge.stops
      await("Stop settles only the current parent") do
        chat.turns.list.items.find { |turn| turn.public_id == running.public_id }&.status == "canceled"
      end
      assert_equal "running", side.turns.list.items.find { |turn| turn.public_id == side_turn.public_id }.status
      # The side has begun on the public execution plane but no reconciliation
      # tick has filled its mapping. Reply targeting must resolve that exact work.
      side_stop = update(7, "/stop")
      side_stop.fetch("message")["reply_to_message"] = side_source
      @bridge.lose_next_stop_ack = true
      assert_raises(Rho::ConnectionError) { @runtime.consume(side_stop) }
      boot_runtime(allowed: [101])
      @runtime.consume(side_stop)
      @runtime.consume(side_stop)
      assert_equal [running.active_variant.agent_loop_public_id, side_turn.active_variant.agent_loop_public_id], @bridge.stops
      await("reply Stop settles only the original side execution") do
        side.turns.list.items.find { |turn| turn.public_id == side_turn.public_id }&.status == "canceled"
      end
      assert_equal "awaiting_input", telegram_question_task(old_turn).status
      assert_equal "running", old_side.turns.list.items.find { |turn| turn.public_id == old_side_turn.public_id }.status
      assert_equal chat.public_id, current("101:0")
      assert_empty @logs
    ensure
      # End the old work through the same public control surface once its
      # independence is proven; it must not outlive the journey's daemon.
      @core.stop(old_chat.public_id) if old_chat
      @core.stop(old_side.public_id) if old_side
    end

    module Helpers
      private

        def telegram_held_parent(id, chat: 101, topic: nil, user: 101, expected_kind: "ask", reply: "main-answer", prior_tool_answers: 0)
          arguments = CGI.escape(JSON.generate("prompt" => "Continue this main request?"))
          script = (["ask:#{arguments}"] * (prior_tool_answers + 1)).join(",")
          text = "!mock tool_call=#{script} reply=#{reply} -- keep the main request open"
          text = "@rho_bot\n#{text}" if chat.negative?
          incoming = update(id, text, user: user, chat: chat, topic: topic, mention: chat.negative?)
          @runtime.consume(incoming)
          conversation_id = current("#{chat}:#{topic || 0}", user: user)
          conversation = @workspace.conversation(conversation_id)
          question_id, question = await("the main request's Telegram question") do
            tick
            @state.read.fetch("questions").find do |_key, row|
              row["conversation_id"] == conversation_id && row["kind"] == expected_kind && !row["resolved"]
            end
          end
          assert_equal expected_kind, question.fetch("kind")
          turn = conversation.turns.list.items.find do |row|
            row.active_variant&.agent_loop_public_id == question.fetch("loop_public_id")
          end
          refute_nil turn
          assert_equal "running", turn.status
          [conversation, turn, question_id, incoming.fetch("message")]
        end

        def telegram_question_task(turn)
          context = @workspace.agent_loops.agent_loop(turn.active_variant.agent_loop_public_id)
          context.fetch.tasks.find(&:await?)
        end

        def telegram_side_id(route_key, parent_id, user: 101)
          sides = @state.read.fetch("routes").fetch(telegram_route_key(route_key, user: user)).fetch("conversations").select do |_id, row|
            row["side_parent"] == parent_id
          end
          assert_equal 1, sides.length, "one reusable side follows this parent in its source route"
          sides.keys.first
        end

        def telegram_streaming_side(id, parent_id, marker)
          # The provider streams for about 38 seconds, but the journey waits only
          # for its public running state and cancels it. No completion race opens
          # the cancellation window and no tool is needed to hold a side open.
          words = "#{marker} #{"x" * 3400}"
          incoming = update(id, "/btw !mock stream_chunk_delay=0.2 reply=#{CGI.escape(words)} -- keep answering")
          @runtime.consume(incoming)
          side = @workspace.conversation(telegram_side_id("101:0", parent_id))
          running = await("the side begins its streamed answer") do
            side.turns.list.items.find { |turn| !turn.inherited && turn.kind == "direct_reply" && turn.status == "running" }
          end
          [side, running, incoming.fetch("message")]
        end

        def telegram_request_text(request)
          request.entries.flat_map { |entry| entry.fetch("parts", []).filter_map { |part| part["text"] } }.join("\n")
        end
    end
  end
end
