module E2E
  # Telegram updates cross the real Core, daemon and Nexus input lane. An ask
  # keeps the parent at a model boundary until this journey answers it.
  module RhoTelegramCommands
    def test_telegram_steer_joins_the_running_turn_while_an_ordinary_message_waits
      boot_runtime(allowed: [101])
      chat, running, question_id = telegram_held_parent(1)
      loop_id = running.active_variant.run_public_id

      queued_text = "!mock reply=queued-answer -- answer in the next turn"
      receive(update(2, queued_text))
      steer_text = "!mock reply=steered-answer -- use the revised instruction now"
      steering_update = update(3, "/steer #{steer_text}")
      receive(steering_update)
      receive(steering_update)
      inputs = chat.inputs.list.items
      assert_equal [queued_text, steer_text], inputs.map(&:text)
      assert_equal %w[queue steer], inputs.map(&:delivery_mode)
      assert_equal %w[pending steering], inputs.map(&:state)
      assert_equal 1, chat.turns.list.items.count { |turn| turn.kind == "direct_reply" }
      assert_equal "awaiting_input", telegram_question_task(running).status

      receive(update(4, "/answer #{question_id} Continue"))
      replies = await("the steered answer and the queued turn") do
        tick
        rows = chat.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
        rows if rows.length == 2
      end
      assert_equal ["Mock: steered-answer", "Mock: queued-answer"], replies.map { |turn| turn.active_variant.content }
      assert_equal running.public_id, replies.first.public_id
      assert_equal loop_id, replies.first.active_variant.run_public_id
      refute_equal loop_id, replies.last.active_variant.run_public_id

      events = chat.events(limit: 100).items
      landed = events.find do |event|
        event.type == "input_materialized" && event.payload["input_public_id"] == inputs.last.public_id
      end
      refute_nil landed
      assert_equal running.public_id, landed.payload.fetch("turn_public_id")
      assert_equal loop_id, landed.payload.fetch("run_public_id")
      refute_equal "r1", landed.payload.fetch("task_key")
      request = @workspace.runs.run(loop_id).tasks_context(landed.payload.fetch("task_key")).request
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

    module Helpers
      private

        def telegram_held_parent(id, chat: 101, topic: nil, user: 101, expected_kind: "ask", reply: "main-answer", prior_tool_answers: 0)
          arguments = CGI.escape(JSON.generate("prompt" => "Continue this main request?"))
          script = (["ask:#{arguments}"] * (prior_tool_answers + 1)).join(",")
          text = "!mock tool_call=#{script} reply=#{reply} -- keep the main request open"
          text = "@rho_bot\n#{text}" if chat.negative?
          incoming = update(id, text, user: user, chat: chat, topic: topic, mention: chat.negative?)
          receive(incoming)
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
            row.active_variant&.run_public_id == question.fetch("run_public_id")
          end
          refute_nil turn
          assert_equal "running", turn.status
          [conversation, turn, question_id, incoming.fetch("message")]
        end

        def telegram_question_task(turn)
          context = @workspace.runs.run(turn.active_variant.run_public_id)
          context.fetch.tasks.find(&:await?)
        end

        def telegram_request_text(request)
          request.entries.flat_map { |entry| entry.fetch("parts", []).filter_map { |part| part["text"] } }.join("\n")
        end
    end
  end
end
