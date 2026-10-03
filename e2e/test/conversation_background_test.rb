require_relative "conversation_turn_test"

class ConversationTurnTest
  def test_a_fast_background_result_waits_for_a_separate_supplementary_reply
    boot_rho!
    output = "early-result-#{SecureRandom.hex(6)}"
    script = "g.tool({name: 'bash', input: {command: 'printf #{output}'}, key: 'early'});"
    background = CGI.escape(JSON.generate("script" => script))
    foreground = CGI.escape(JSON.generate("prompt" => "Finish the original answer?"))
    conversation, first_loop = rho_open("!mock tool_call=compose:#{background}&ask:#{foreground} -- original answer")
    chat = steward_conversation(conversation)
    context = rho_loops.agent_loop(first_loop)
    early, question = await("the background result completing while the original question is open") do
      tasks = context.fetch.tasks
      result = tasks.find { |task| task.key.end_with?("-early") && task.status == "completed" }
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
    refute_equal first_loop, supplementary.active_variant.agent_loop_public_id
    events = chat.events(limit: 200)
    receipts = events.select do |event|
      event.type == "input_accepted" && event.payload["origin"] == "task_result" &&
        event.payload["agent_loop_public_id"] == first_loop
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
    request = rho_loops.agent_loop(supplementary.active_variant.agent_loop_public_id).tasks_context("r1").request
    material = request.entries.flat_map { |entry| entry.fetch("parts", []).filter_map { |part| part["text"] } }
    assert material.any? { |text| text.include?(output) }, "the new reply must read the original background result"
  end

  def test_conversation_stop_cancels_previous_background_and_current_work_without_restarting_either
    boot_rho!
    script = 'g.ask({prompt: "Continue the earlier background work?", key: "old_question"});'
    arguments = CGI.escape(JSON.generate("script" => script))
    conversation, first_loop = rho_open("!mock tool_call=compose tool_args=#{arguments} -- original answer")
    chat = steward_conversation(conversation)
    original = await_settled_reply(chat).items.last
    original_content = original.active_variant.content
    old = rho_loops.agent_loop(first_loop)
    question = await("the previous turn's live background question") do
      old.fetch.tasks.find { |task| task.key.end_with?("-old_question") && task.status == "awaiting_input" }
    end
    foreground = CGI.escape(JSON.generate("prompt" => "Continue the current work?"))
    said, status = @daemon.cli("say", conversation, "!mock tool_call=ask,ask tool_args=#{foreground} -- next answer")
    assert_predicate status, :success?, said
    next_loop = said[/^loop:\s+(\S+)/, 1]
    refute_nil next_loop, said
    await("the current turn's question") do
      rho_loops.fetch(next_loop).tasks.any? { |task| task.kind == "await_task" && task.status == "awaiting_input" }
    end

    stopped, status = @daemon.cli("stop", conversation)
    assert_predicate status, :success?, stopped
    [first_loop, next_loop].each { |loop_id| await_rho_loop(loop_id, "canceled") }
    assert_equal "canceled", old.fetch.tasks.find { |task| task.key == question.key }.status
    late = old.tasks_context(question.key).resolve(content: "Too late")
    assert_equal "canceled", late.dig("task", "status"), "a late answer must leave the canceled task unchanged"
    preserved = chat.turns.list.items.find { |turn| turn.public_id == original.public_id }
    assert_equal "completed", preserved.status
    assert_equal original_content, preserved.active_variant.content

    resumed, status = @daemon.cli("say", conversation, "!mock -- a new independent request")
    assert_predicate status, :success?, resumed
    new_loop = resumed[/^loop:\s+(\S+)/, 1]
    refute_nil new_loop, resumed
    await_rho_loop(new_loop, "completed")
    stopped_mail = chat.events(limit: 200).select do |event|
      event.type == "input_accepted" && event.payload["origin"] == "task_result" &&
        [first_loop, next_loop].include?(event.payload["agent_loop_public_id"])
    end
    assert_empty stopped_mail, "stopped owners must not produce a supplementary reply after new work resumes"
  end

  def test_a_waited_compose_preserves_shared_input_and_race_selection_through_a_checkpoint
    boot_rho!
    script = <<~JS
      const diff = g.tool({name: "bash", input: {command: "printf shared-patch-output"}, key: "diff"});
      const race = g.parallel([
        g.model({prompt: "Review the patch.", results: [diff], key: "review"}),
        g.ask({prompt: "An alternative that should be canceled", key: "loser"})
      ], {until: "any"});
      const checkpoint = g.tool({name: "bash", input: {command: "printf checkpoint-output"}, key: "checkpoint"});
      g.model({prompt: "Synthesize the patch and review.", results: [diff, race, checkpoint], key: "synthesis"});
    JS
    arguments = CGI.escape(JSON.generate("script" => script, "wait" => true))
    _conversation, loop_id = rho_open("!mock tool_call=compose tool_args=#{arguments} -- report the review")
    settled = await_rho_loop(loop_id, "completed")
    tasks = %w[diff review loser checkpoint synthesis].to_h do |key|
      task = settled.tasks.find { |candidate| candidate.key.end_with?("-#{key}") }
      refute_nil task, "missing composed task #{key}"
      [key, task]
    end
    assert_equal "canceled", tasks.fetch("loser").status
    request = rho_loops.agent_loop(loop_id).tasks_context(tasks.fetch("synthesis").key).request
    texts = request.entries.select { |entry| entry["role"] == "user" }
      .flat_map { |entry| entry.fetch("parts").filter_map { |part| part["text"] } }
    { "diff" => "shared-patch-output", "checkpoint" => "checkpoint-output" }.each do |key, output|
      assert_includes texts, E2E::PrintedEnvelope.of(tasks.fetch(key).key, output),
        "the synthesis must receive #{key}'s own result, which it names: its body on the line after its call"
    end
    assert request.entries.none? { |entry| entry["role"] == "assistant" }, "a composed step continues no one's conversation"
    refute texts.any? { |text| text.start_with?("<answer task=\"#{tasks.fetch("loser").key}\"") }
  end

  def test_a_background_compose_ending_in_a_race_delivers_its_winner_before_the_turn_finishes
    boot_rho!
    script = <<~JS
      g.parallel([
        g.tool({name: "bash", input: {command: "printf race-winner-output"}, key: "winner"}),
        g.ask({prompt: "An alternative that should be canceled", key: "loser"})
      ], {until: "any"});
    JS
    arguments = CGI.escape(JSON.generate("script" => script, "lifetime" => "turn"))
    conversation, loop_id = rho_open("!mock tool_call=compose tool_args=#{arguments} -- summarize the winner")
    chat = steward_conversation(conversation)
    loop_context = rho_loops.agent_loop(loop_id)
    settled = await_rho_loop(loop_id, "completed")
    reply = await_settled_reply(chat).items.last
    winner = settled.tasks.find { |task| task.key.end_with?("-winner") }
    loser = settled.tasks.find { |task| task.key.end_with?("-loser") }
    refute_nil winner
    refute_nil loser
    assert_equal "completed", winner.status
    assert_equal "canceled", loser.status

    events = chat.events(limit: 200)
    receipts = events.select do |event|
      event.type == "input_accepted" && event.payload["origin"] == "task_result" &&
        event.payload["agent_loop_public_id"] == loop_id
    end
    assert_equal [winner.key], receipts.map { |event| event.payload.fetch("task_key") },
      "the terminal race must deliver its winner exactly once, without its canceled alternative"
    completion = events.find do |event|
      event.type == "turn_status" && event.payload["turn_public_id"] == reply.public_id &&
        event.payload["status"] == "completed"
    end
    refute_nil completion
    assert_operator receipts.first.sequence, :<, completion.sequence

    request = loop_context.tasks_context(settled.deliverable_task_key).request
    material = request.entries.select { |entry| entry["role"] == "user" }
      .flat_map { |entry| entry.fetch("parts").filter_map { |part| part["text"] } }
      .select { |text| text.start_with?("<task_result ") }
    assert_equal 1, material.count { |text| text.include?("task=\"#{winner.key}\"") }
    assert_includes material, E2E::PrintedEnvelope.of(winner.key, "race-winner-output"),
      "the winner's actual output must reach the final model request, on the line after its call"
    refute material.any? { |text| text.include?("task=\"#{loser.key}\"") }
  end

  def test_a_background_question_before_the_final_answer_does_not_hold_the_turn_open
    boot_rho!
    script = 'g.ask({prompt: "May the background work continue?", key: "background_question"});'
    composed = CGI.escape(JSON.generate("script" => script))
    busy = CGI.escape(JSON.generate("command" => "sleep #{E2E::RhoDaemon::HOLD_SECONDS}"))
    conversation, first_loop = rho_open("!mock tool_call=compose:#{composed}&bash:#{busy} -- first answer")
    chat = steward_conversation(conversation)
    original_loop = rho_loops.agent_loop(first_loop)
    question = await("the background question while the foreground tool runs") do
      original_loop.fetch.tasks.find { |task| task.kind == "await_task" && task.status == "awaiting_input" }
    end
    attention = await("the background question on the conversation feed") do
      chat.events(limit: 200).find do |event|
        event.type == "attention_required" && event.payload.fetch("blocked_task_keys").include?(question.key)
      end
    end

    original = await_settled_reply(chat).items.last
    completed = chat.events(limit: 200).find do |event|
      event.type == "turn_status" && event.payload["turn_public_id"] == original.public_id &&
        event.payload["status"] == "completed"
    end
    refute_nil completed
    assert_operator attention.sequence, :<, completed.sequence,
      "the question must precede the final answer; the foreground hold alone is not proof of ordering"
    assert_equal [original.public_id, original.active_variant.public_id, first_loop],
      attention.payload.values_at("turn_public_id", "variant_public_id", "agent_loop_public_id")
    assert_equal "awaiting_input", original_loop.fetch.tasks.find { |task| task.key == question.key }.status,
      "the parent turn completes without answering its detached question"
    refute_predicate chat.fetch, :busy?
    await_follower(conversation, loop: first_loop)

    said, status = @daemon.cli("say", conversation, "!mock -- second answer")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    next_loop = said[/^loop:\s+(\S+)/, 1]
    refute_nil next_loop, "rho say named no new loop:\n#{said}"
    refute_equal first_loop, next_loop
    await_rho_loop(next_loop, "completed")

    resolution = original_loop.tasks_context(question.key)
    resolution.resolve(content: "Continue")
    await_rho_loop(first_loop, "completed")
    receipt = await("the earlier background question's receipt") do
      chat.events(limit: 200).find do |event|
        event.type == "input_accepted" && event.payload["origin"] == "task_result" &&
          event.payload["agent_loop_public_id"] == first_loop && event.payload["task_key"] == question.key
      end
    end
    resolution.resolve(content: "Continue")
    receipts = chat.events(limit: 200).select do |event|
      event.type == "input_accepted" && event.payload["origin"] == "task_result"
    end
    assert_equal [receipt.sequence], receipts.map(&:sequence),
      "answering the earlier question twice must deliver one receipt under its original loop"
  end

  def test_a_previous_turns_background_question_does_not_replace_the_current_execution
    boot_rho!
    script = <<~JS
      g.tool({name: "bash", input: {command: "sleep #{E2E::RhoDaemon::HOLD_SECONDS}"}, key: "delay"});
      g.ask({prompt: "May the earlier background work continue?", key: "old_question"});
    JS
    arguments = CGI.escape(JSON.generate("script" => script))
    conversation, first_loop = rho_open("!mock tool_call=compose tool_args=#{arguments} -- first answer")
    chat = steward_conversation(conversation)
    original = await_settled_reply(chat).items.last
    await_follower(conversation, loop: first_loop)

    # One tool answer is already in history. The second scripted call keeps
    # the new turn running while the earlier detached sequence asks its question.
    busy = CGI.escape(JSON.generate("command" => "sleep #{2 * E2E::RhoDaemon::HOLD_SECONDS}"))
    said, status = @daemon.cli("say", conversation, "!mock tool_call=bash,bash tool_args=#{busy} -- second answer")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    next_loop = said[/^loop:\s+(\S+)/, 1]
    refute_nil next_loop, "rho say named no new loop:\n#{said}"
    refute_equal first_loop, next_loop
    started = await("the next turn's running tool") do
      row = background_follower(conversation)
      row if row["loop"] == next_loop && row.fetch("tasks").any? do |task|
        task["kind"] == "tool_task" && task["status"] == "dispatched"
      end
    end
    refute_equal original.public_id, started.fetch("turn")

    old = rho_loops.agent_loop(first_loop)
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
    assert_equal next_loop, followed.fetch("loop"), followed.inspect
    assert_equal started.fetch("turn"), followed.fetch("turn"), followed.inspect
    assert_nil followed["attention"],
      "the previous loop's question is not the current turn's attention: #{followed.except("frames").inspect}"
    refute_includes followed.fetch("tasks").map { |task| task.fetch("task_key") }, question.key,
      "the earlier loop's task must not join the current task table"
    assert_equal current.tasks.map(&:key).sort, followed.fetch("tasks").map { |task| task.fetch("task_key") }.sort
    producer = [original.public_id, original.active_variant.public_id, first_loop]
    assert_equal producer, attention.payload.values_at("turn_public_id", "variant_public_id", "agent_loop_public_id")
    task_event = chat.events(limit: 200).find do |event|
      event.type == "task_status" && event.payload["task_key"] == question.key && event.payload["status"] == "awaiting_input"
    end
    refute_nil task_event
    assert_equal producer, task_event.payload.values_at("turn_public_id", "variant_public_id", "agent_loop_public_id")

    # No step reads the delay, so it comes back beside the question: each unread step of the chain
    # has its own receipt, in settlement order, and none before the chain's last step settled.
    delay = old.fetch.tasks.find { |task| task.key.end_with?("-delay") }
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
      mailed.map { |event| event.payload.values_at("agent_loop_public_id", "task_key") },
      "each unread step of the earlier chain comes back under the loop that composed it, once"
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
    assert_equal next_loop, received.fetch("loop")
    assert_nil received["attention"]
    assert_equal [[first_loop, delay.key], [first_loop, question.key]],
      received.fetch("mailed").map { |receipt| receipt.values_at("agent_loop_public_id", "task_key") }
    assert_empty received.fetch("tasks").map { |task| task.fetch("task_key") } & [delay.key, question.key],
      "the earlier loop's tasks must not join the current task table"
    await_rho_loop(next_loop, "completed")
  end

  # THE WOKEN TURN IS THE EARLIER REQUEST WHOLE. rho's environment lead rides a person's turn as that
  # turn's preface, behind history; the receipt a detached task mails wakes the next turn with no lead
  # of its own, and that turn's round one opens with the mailing loop's LAST spine request, entry for
  # entry — the person's lead where it was sent, once — so a provider's cache over that request, and
  # every thinking block signed under it, still hold. Read through the member plane's sealed requests.
  # The brief scripts a slow `bash` so this row exercises completion after the original reply.
  def test_a_receipt_woken_turns_sealed_request_is_the_previous_turns_request_whole
    boot_rho!
    slow = CGI.escape(JSON.generate("command" => "sleep #{E2E::RhoDaemon::HOLD_SECONDS}"))
    brief = CGI.escape(JSON.generate("prompt" => "!mock tool_call=bash tool_args=#{slow} -- done: found it"))
    conversation, first_loop = rho_open("!mock tool_call=task tool_args=#{brief} -- answer")
    chat = steward_conversation(conversation)
    settled = await_rho_loop(first_loop, "completed")
    await("the detached task's receipt") do
      chat.events(limit: 200).find do |event|
        event.type == "input_accepted" && event.payload["origin"] == "task_result" &&
          event.payload["agent_loop_public_id"] == first_loop
      end
    end
    woken_loop = await("the turn the receipt woke, settled") do
      woken = chat.turns.list.items.find do |turn|
        turn.kind == "direct_reply" && turn.active_variant.agent_loop_public_id != first_loop
      end
      woken.active_variant.agent_loop_public_id if woken&.status == "completed"
    end

    last = rho_loops.agent_loop(first_loop).tasks_context(settled.deliverable_task_key).request.entries
    woken_r1 = rho_loops.agent_loop(woken_loop).tasks_context("r1").request.entries
    assert_equal last, woken_r1.first(last.length),
      "the woken turn's round one opens with the mailing loop's last request, entry for entry"
    assert_equal 1, lead_indexes(last).length, "rho's lead rode the person's turn once: #{last.map { |e| e["role"] || e["type"] }}"
    assert_equal lead_indexes(last), lead_indexes(woken_r1),
      "the receipt's turn sends no lead of its own; the person's stands where that turn sent it"
    receipt = woken_r1.last
    assert_equal "user", receipt["role"]
    text_parts = receipt.fetch("parts").filter_map { |part| part["text"] }
    assert_equal "Conversation kind: conversation.", text_parts.first
    assert text_parts.last.start_with?("<task_result task=\"r2t0\""),
      "the receipt is the woken turn's trailing user text: #{receipt.inspect}"
  end

  private

    # The entries that carry rho's environment lead: a developer-role message opening with its
    # root sentence.
    def lead_indexes(entries)
      entries.each_index.select do |index|
        entry = entries[index]
        entry["role"] == "developer" &&
          entry.fetch("parts").first&.fetch("text", nil).to_s.start_with?("Relative paths resolve against")
      end
    end

    def background_follower(conversation)
      @daemon.control(:get, "/loops").fetch("loops").find { |row| row.fetch("public_id") == conversation }
    end
end
