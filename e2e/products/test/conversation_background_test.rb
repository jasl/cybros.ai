require_relative "turn_test"

class TurnTest
  def test_a_fast_background_result_waits_for_a_separate_supplementary_reply
    boot_rho!
    output = "early-result-#{SecureRandom.hex(6)}"
    background = background_code([{ "tool" => { "name" => "bash", "route" => rho_runner_route, "input" => { "command" => "printf #{output}" }, "key" => "early" } }])
    foreground = CGI.escape(JSON.generate("prompt" => "Finish the original answer?"))
    conversation, first_loop = rho_open("!mock tool_call=code:#{background}&ask:#{foreground} -- original answer")
    chat = steward_conversation(conversation)
    context = rho_loops.run(first_loop)
    early, question = await("the background result completing while the original question is open") do
      tasks = context.fetch.tasks
      result = background_task(context, "early")
      result = nil unless result&.status == "completed"
      ask = tasks.find { |task| task.kind == "await_task" && task.status == "awaiting_input" }
      [result, ask] if result && ask
    end
    original = chat.turns.list.items.last
    assert_equal "running", original.status
    early_mail = chat.events(limit: 200).select do |event|
      event.type == "input_accepted" && event.payload["origin"] == "task_result"
    end
    assert_empty early_mail

    context.tasks_context(question.key).resolve(content: "Finish")
    supplementary = await("a completed supplementary reply in a different turn") do
      chat.turns.list.items.find do |turn|
        turn.public_id != original.public_id && turn.kind == "direct_reply" && turn.status == "completed"
      end
    end
    refute_equal first_loop, supplementary.active_variant.run_public_id
    events = chat.events(limit: 200)
    receipts = events.select do |event|
      event.type == "input_accepted" && event.payload["origin"] == "task_result" &&
        event.payload["run_public_id"] == first_loop
    end
    assert_equal [early.key], receipts.map { |event| event.payload.fetch("task_key") }
    refute_nil receipts.first.payload["input_public_id"], "supplementary mail must be a durable input"
    completed = events.find do |event|
      event.type == "turn_status" && event.payload["turn_public_id"] == original.public_id &&
        event.payload["status"] == "completed"
    end
    refute_nil completed
    early_completion = events.find do |event|
      event.type == "task_status" && event.payload["task_key"] == early.key &&
        event.payload["status"] == "completed"
    end
    assert_operator early_completion.sequence, :<, completed.sequence
    materialized = events.find do |event|
      event.type == "input_materialized" &&
        event.payload["input_public_id"] == receipts.first.payload.fetch("input_public_id")
    end
    refute_nil materialized
    assert_operator completed.sequence, :<, materialized.sequence
    request = rho_loops.run(supplementary.active_variant.run_public_id).tasks_context("r1").request
    material = request.entries.flat_map { |entry| entry.fetch("parts", []).filter_map { |part| part["text"] } }
    assert material.any? { |text| text.include?(output) }, "the new reply must read the original background result"
  end

  def test_conversation_stop_cancels_previous_background_and_current_work_without_restarting_either
    boot_rho!
    arguments = background_code([{ "ask" => { "prompt" => "Continue the earlier background work?", "key" => "old_question" } }])
    conversation, first_loop = rho_open("!mock tool_call=code tool_args=#{arguments} -- original answer")
    chat = steward_conversation(conversation)
    original = await_settled_reply(chat).items.last
    original_content = original.active_variant.content
    old = rho_loops.run(first_loop)
    question = await("the previous turn's live background question") do
      background_task(old, "old_question")&.then { |task| task if task.status == "awaiting_input" }
    end
    foreground = CGI.escape(JSON.generate("prompt" => "Continue the current work?"))
    said, status = @daemon.cli("say", conversation, "!mock tool_call=ask,ask tool_args=#{foreground} -- next answer")
    assert_predicate status, :success?, said
    next_loop = said[/^run:\s+(\S+)/, 1]
    refute_nil next_loop, said
    await("the current turn's question") do
      rho_loops.fetch(next_loop).tasks.any? { |task| task.kind == "await_task" && task.status == "awaiting_input" }
    end

    stopped, status = @daemon.cli("stop", conversation)
    assert_predicate status, :success?, stopped
    [first_loop, next_loop].each { |loop_id| await_rho_loop(loop_id, "canceled") }
    assert_equal "canceled", old.fetch.tasks.find { |task| task.key == question.key }.status
    late = old.tasks_context(question.key).resolve(content: "Too late")
    assert_equal "canceled", late.status, "a late answer must leave the canceled task unchanged"
    preserved = chat.turns.list.items.find { |turn| turn.public_id == original.public_id }
    assert_equal "completed", preserved.status
    assert_equal original_content, preserved.active_variant.content

    resumed, status = @daemon.cli("say", conversation, "!mock -- a new independent request")
    assert_predicate status, :success?, resumed
    new_loop = resumed[/^run:\s+(\S+)/, 1]
    refute_nil new_loop, resumed
    await_rho_loop(new_loop, "completed")
    stopped_mail = chat.events(limit: 200).select do |event|
      event.type == "input_accepted" && event.payload["origin"] == "task_result" &&
        [first_loop, next_loop].include?(event.payload["run_public_id"])
    end
    assert_empty stopped_mail, "stopped owners must not produce a supplementary reply after new work resumes"
  end

  def test_a_waited_code_batch_preserves_shared_input_and_race_selection_through_a_checkpoint
    boot_rho!
    steps = [
      { "tool" => { "name" => "bash", "route" => rho_runner_route, "input" => { "command" => "printf shared-patch-output" }, "key" => "diff" } },
      { "parallel" => [
        { "model" => { "prompt" => "Review the patch.", "results" => ["diff"], "key" => "review" } },
        { "ask" => { "prompt" => "An alternative that should be canceled", "key" => "loser" } },
      ], "until" => "any", "key" => "race" },
      { "tool" => { "name" => "bash", "route" => rho_runner_route, "input" => { "command" => "printf checkpoint-output" }, "key" => "checkpoint" } },
      { "model" => { "prompt" => "Synthesize the patch and review.", "results" => %w[diff race checkpoint], "key" => "synthesis" } },
    ]
    arguments = CGI.escape(JSON.generate("code" => "text(JSON.stringify(await nexus.steps(#{JSON.generate(steps)})));"))
    _conversation, loop_id = rho_open("!mock tool_call=code tool_args=#{arguments} -- report the review")
    await_rho_loop(loop_id, "completed")
    context = rho_loops.run(loop_id)
    tasks = result_dag_tasks(context, { "diff" => "printf shared-patch-output", "review" => "Review the patch.",
      "loser" => "An alternative that should be canceled", "checkpoint" => "printf checkpoint-output",
      "synthesis" => "Synthesize the patch and review." })
    assert tasks.values.none?(nil), "missing authored task: #{tasks.inspect}"
    assert_equal "canceled", tasks.fetch("loser").status
    request = rho_loops.run(loop_id).tasks_context(tasks.fetch("synthesis").key).request
    texts = request.entries.select { |entry| entry["role"] == "user" }
      .flat_map { |entry| entry.fetch("parts").filter_map { |part| part["text"] } }
    { "diff" => "shared-patch-output", "checkpoint" => "checkpoint-output" }.each do |key, output|
      assert_includes texts, E2E::PrintedEnvelope.of(tasks.fetch(key).key, output),
        "the synthesis must receive #{key}'s own result, which it names: its body on the line after its call"
    end
    assert request.entries.none? { |entry| entry["role"] == "assistant" }, "an independently authored model continues no one's conversation"
    refute texts.any? { |text| text.start_with?("<answer task=\"#{tasks.fetch("loser").key}\"") }
  end

  def test_a_previous_turns_background_question_does_not_replace_the_current_execution
    boot_rho!
    arguments = background_code([
      { "tool" => { "name" => "bash", "route" => rho_runner_route, "input" => { "command" => "sleep #{E2E::RhoDaemon::HOLD_SECONDS}" }, "key" => "delay" } },
      { "ask" => { "prompt" => "May the earlier background work continue?", "key" => "old_question" } },
    ])
    conversation, first_loop = rho_open("!mock tool_call=code tool_args=#{arguments} -- first answer")
    chat = steward_conversation(conversation)
    original = await_settled_reply(chat).items.last
    await_follower(conversation, loop: first_loop)

    # One tool answer is already in history. The second scripted call keeps
    # the new turn running while the earlier detached sequence asks its question.
    busy = CGI.escape(JSON.generate("command" => "sleep #{2 * E2E::RhoDaemon::HOLD_SECONDS}"))
    said, status = @daemon.cli("say", conversation, "!mock tool_call=bash,bash tool_args=#{busy} -- second answer")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    next_loop = said[/^run:\s+(\S+)/, 1]
    refute_nil next_loop, "rho say named no new loop:\n#{said}"
    refute_equal first_loop, next_loop
    started = await("the next turn's running tool") do
      row = background_follower(conversation)
      row if row["run_public_id"] == next_loop && row.fetch("tasks").any? do |task|
        task["kind"] == "tool_task" && task["status"] == "dispatched"
      end
    end
    refute_equal original.public_id, started.fetch("turn")

    old = rho_loops.run(first_loop)
    question = await("the earlier loop's background question") do
      old.fetch.tasks.find { |task| task.kind == "await_task" && task.status == "awaiting_input" }
    end
    attention = await("the earlier question on the conversation feed") do
      chat.events(limit: 200).find do |event|
        event.type == "attention_required" && event.payload.fetch("blocked_task_keys").include?(question.key)
      end
    end
    assert_operator attention.sequence, :>, started.fetch("sequence"),
      "the old question must arrive after rho has followed the next turn"
    followed = await("rho consuming the background question's event") do
      row = background_follower(conversation)
      row if row.fetch("sequence") >= attention.sequence
    end
    current = rho_loops.fetch(next_loop)
    assert current.tasks.any? { |task| task.kind == "tool_task" && task.status == "dispatched" },
      "the current turn must still be running when the old question arrives"
    assert_equal next_loop, followed.fetch("run_public_id"), followed.inspect
    assert_equal started.fetch("turn"), followed.fetch("turn"), followed.inspect
    assert_nil followed["attention"],
      "the previous loop's question is not the current turn's attention: #{followed.except("frames").inspect}"
    refute_includes followed.fetch("tasks").map { |task| task.fetch("task_key") }, question.key,
      "the earlier loop's task must not join the current task table"
    assert_equal current.tasks.map(&:key).sort, followed.fetch("tasks").map { |task| task.fetch("task_key") }.sort
    producer = [original.public_id, original.active_variant.public_id, first_loop]
    assert_equal producer, attention.payload.values_at("turn_public_id", "variant_public_id", "run_public_id")
    task_event = chat.events(limit: 200).find do |event|
      event.type == "task_status" && event.payload["task_key"] == question.key && event.payload["status"] == "awaiting_input"
    end
    refute_nil task_event
    assert_equal producer, task_event.payload.values_at("turn_public_id", "variant_public_id", "run_public_id")

    # No step reads the delay, so it comes back beside the question: each unread step of the chain
    # has its own receipt, in settlement order, and none before the chain's last step settled.
    delay = background_task(old, "delay")
    refute_nil delay
    assert_equal "completed", delay.status, "the delay settled before its chain asked"
    old.tasks_context(question.key).resolve(content: "Continue")
    await_rho_loop(first_loop, "completed")
    receipts = lambda do
      chat.events(limit: 200).select do |event|
        event.type == "input_accepted" && event.payload["origin"] == "task_result"
      end
    end
    await("the earlier question's receipt") { receipts.call.find { |event| event.payload["task_key"] == question.key } }
    mailed = receipts.call
    assert_equal [[first_loop, delay.key], [first_loop, question.key]],
      mailed.map { |event| event.payload.values_at("run_public_id", "task_key") },
      "each unread step of the earlier chain comes back under the loop that launched it, once"
    answered = chat.events(limit: 200).find do |event|
      event.type == "task_status" && event.payload["task_key"] == question.key && event.payload["status"] == "completed"
    end
    refute_nil answered
    assert_operator answered.sequence, :<, mailed.first.sequence,
      "the settled delay waits for its chain: nothing comes back while the question is open"
    received = await("rho retaining the background receipts without changing the current execution") do
      row = background_follower(conversation)
      row if row.fetch("sequence") >= mailed.last.sequence
    end
    assert_equal next_loop, received.fetch("run_public_id")
    assert_nil received["attention"]
    assert_equal [[first_loop, delay.key], [first_loop, question.key]],
      received.fetch("delivered_results").map { |receipt| receipt.values_at("run_public_id", "task_key") }
    assert_empty received.fetch("tasks").map { |task| task.fetch("task_key") } & [delay.key, question.key],
      "the earlier loop's tasks must not join the current task table"
    await_rho_loop(next_loop, "completed")
  end

  private

    def background_follower(conversation)
      @daemon.control(:get, "/followers").fetch("followers").find { |row| row.fetch("public_id") == conversation }
    end
end
