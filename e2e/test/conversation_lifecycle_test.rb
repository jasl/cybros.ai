require_relative "conversation_turn_test"

class ConversationTurnTest
  def test_passive_completion_is_history_without_an_automatic_model_reply
    boot_rho!
    chat, context, question = open_passive_question
    answer = "passive-result-#{SecureRandom.hex(6)}"
    context.tasks_context(question.key).resolve(content: answer)
    await_rho_loop(context.agent_loop_public_id, "completed")
    receipt = await("the passive completion message") do
      chat.turns.list.items.find { |turn| turn.origin == "task_result" }
    end

    assert_equal "message", receipt.kind
    assert_includes receipt.text, answer
    refute_predicate chat.fetch, :busy?
    assert_equal 1, chat.turns.list.items.count { |turn| turn.kind == "direct_reply" }

    loop_id = say_lifecycle(chat.public_id, "!mock -- summarize the background result")
    completed = await_rho_loop(loop_id, "completed")
    assert_includes rho_loops.agent_loop(loop_id).task(completed.deliverable_task_key).output, answer
    assert_equal 2, chat.turns.list.items.count { |turn| turn.kind == "direct_reply" }
  end

  def test_later_wait_observes_work_from_an_earlier_turn_without_restarting_it
    boot_rho!(settings: { "kernel_tools" => %w[nexus.graph.compose nexus.graph.wait nexus.human.ask] })
    chat, source, question = open_passive_question
    call = source.fetch.tasks.find { |task| task.tool_name == "compose" }
    arguments = CGI.escape(JSON.generate("task" => call.key, "agent_loop" => source.agent_loop_public_id))
    # The fake advances its script by tool answers in the entire history,
    # including environment binding and the earlier compose launch.
    previous_answers = source.fetch.tasks.count { |task| task.kind == "tool_task" }
    calls = Array.new(previous_answers + 1, "wait").join(",")
    loop_id = say_lifecycle(chat.public_id, "!mock tool_call=#{calls} tool_args=#{arguments} -- report the observed work")
    context = rho_loops.agent_loop(loop_id)
    await("the later wait parked on the earlier work") do
      context.fetch.tasks.find { |task| task.kind == "await_task" && task.status == "dispatched" }
    end
    answer = "joined-result-#{SecureRandom.hex(6)}"
    source.tasks_context(question.key).resolve(content: answer)
    completed = await_rho_loop(loop_id, "completed")

    assert_includes context.task(completed.deliverable_task_key).output, answer
    assert_equal 1, source.fetch.tasks.count { |task| task.kind == "await_task" }
    assert_equal "completed", source.task(question.key).task.status
    refute completed.tasks.any? { |task| task.tool_name == "compose" }
  end

  def test_lifecycle_hooks_cross_the_executor_boundary_and_continue_before_final_delivery
    hook = { "tool" => "lifecycle_check", "timeout_ms" => 30_000 }
    boot_rho!(settings: { "lifecycle_hooks" => {
      "turn_start" => hook, "stop" => hook.merge("max_continuations" => 1),
    } }, extensions: [File.expand_path("../support/lifecycle_extension.rb", __dir__)])
    conversation, loop_id = rho_open("!mock -- first candidate")
    context = rho_loops.agent_loop(loop_id)
    completed = await_rho_loop(loop_id, "completed")
    hooks = completed.tasks.select { |task| task.tool_name == "lifecycle_check" }
      .map { |task| context.task(task.key) }

    assert_equal %w[turn_start stop stop], hooks.map { |detail| detail.tool_input.fetch("event") }
    assert hooks.all? { |detail| detail.task.status == "completed" && detail.task.claimed_by }
    assert_equal [true, false], hooks.drop(1).map { |detail| detail.structured_content.fetch("continue") }
    assert_includes context.task(completed.deliverable_task_key).output, "lifecycle-feedback-verified"
    assert_equal 1, steward_conversation(conversation).turns.list.items.count { |turn| turn.kind == "direct_reply" },
      "hook feedback continues the same reply execution"
  end

  def test_compaction_hooks_bracket_the_repair_before_the_next_model_request
    hook = { "tool" => "lifecycle_check", "timeout_ms" => 30_000 }
    boot_rho!(settings: { "lifecycle_hooks" => { "pre_compact" => hook, "post_compact" => hook } },
      extensions: [File.expand_path("../support/lifecycle_extension.rb", __dir__)])
    arguments = CGI.escape(JSON.generate("command" => "printf 'compaction source'"))
    _conversation, loop_id = rho_open("!mock usage=9000:5 tool_call=bash tool_args=#{arguments} -- continue")
    context = rho_loops.agent_loop(loop_id)
    completed = await_rho_loop(loop_id, "completed")
    hooks = completed.tasks.select { |task| task.tool_name == "lifecycle_check" }
      .map { |task| context.task(task.key) }

    assert_equal %w[pre_compact post_compact], hooks.map { |detail| detail.tool_input.fetch("event") }
    assert hooks.all? { |detail| detail.task.status == "completed" && detail.task.claimed_by }
    assert_includes context.task(completed.deliverable_task_key).output,
      "This summary replaces earlier history"
  end

  private

    def open_passive_question
      arguments = CGI.escape(JSON.generate("wake" => "passive",
        "script" => 'g.ask({prompt: "Supply the background result.", key: "work"});'))
      conversation, loop_id = rho_open("!mock tool_call=compose tool_args=#{arguments} -- initial reply")
      chat = steward_conversation(conversation)
      await_settled_reply(chat)
      context = rho_loops.agent_loop(loop_id)
      question = await("the background question") do
        context.fetch.tasks.find { |task| task.kind == "await_task" && task.status == "awaiting_input" }
      end
      [chat, context, question]
    end

    def say_lifecycle(conversation, prompt)
      output, status = @daemon.cli("say", conversation, prompt)
      assert_predicate status, :success?, output
      loop_id = output[/^loop:\s+(\S+)/, 1]
      refute_nil loop_id, output
      loop_id
    end
end
