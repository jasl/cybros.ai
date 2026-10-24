require_relative "rho_conversation_test"

class RhoConversationTest
  # A BACKGROUND TASK OUTLIVES ITS TURN, ITS RECEIPT WAKES THE NEXT TURN, AND THE PERSON'S EARLIER
  # WORD READS AFTER IT. `delegate_task` runs detached by DEFAULT: the call answers at once and the reply is
  # final — `rho watch` says `completed` and names the work still running — while the branch runs on
  # as the loop's own (its brief scripts a slow `bash`, or the mock's branch would answer before the
  # reply and the wake would deliver it in this turn). The person keeps the lane BUSY with a slow
  # turn 2 and queues a word behind it; the branch's answer lands meanwhile as a kernel-stamped
  # queued `direct_reply` that never steers turn 2 — pinned by the feed's order, or the case
  # degenerates to an idle wake. At turn 2's boundary the drain reads KERNEL ORIGIN FIRST: the first
  # new turn is the kernel's — the receipt is its trailing user text, which the mock echoes, having
  # no directive of its own to read — and the second is the person's, whose history renders the
  # woken turn as its SEED (the envelope, in the user role) then its answer, ahead of their word.
  # The branch's continuation replays the brief's own `!mock` line, whose script it has already
  # spent, so it speaks. Turn 2's script names `bash` twice: the mock counts answers across the
  # whole input, and turn 1's `delegate_task` call is one already. THE HARNESS FACT: the seed puts each
  # person turn's `!mock` line back into every later joined input; the woken turn reads turn 2's
  # line as its marker (the last one present), a `tool_call=bash,bash` script whose calls are
  # already answered, so it speaks. The echo cannot COUNT the delivery (it repeats the whole
  # request), so the once-ness is pinned on the fourth turn's sealed request, never on
  # `task_output`. Turn 1 speaks a scripted `reply=`; the later turns use `echo=content`, which
  # still reads the actual receipt, branch answer and person's word, without copying fixed
  # system/developer instructions into each reply. Full-input usage remains charged. This keeps
  # the fourth turn's history uncompacted, so its once-only seed is observed directly.
  def test_a_background_task_outlives_its_turn_its_receipt_wakes_the_next_turn_and_the_persons_earlier_word_reads_after_it
    project = connect!
    slow = CGI.escape(JSON.generate({ "command" => "sleep #{BRANCH_SLEEP}" }))
    brief = "!mock tool_call=bash tool_args=#{slow} -- done: found it"
    arguments = CGI.escape(JSON.generate({ "prompt" => brief }))
    conversation, turn, loop = open_turn("!mock tool_call=delegate_task tool_args=#{arguments} reply=answered -- answer", project)

    await_feed(conversation, "the turn never completed on the conversation feed") do |items|
      turn_status(items, status: "completed", loop: loop)
    end
    watched, status = @daemon.cli("watch", loop, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
    assert_predicate status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^status:\s+completed$/, watched, watched)
    assert_match(/^background: r3t0 (running|dispatched) — its result reaches the next turn; rho watch #{Regexp.escape(loop)} follows$/,
      watched, "the branch's slow tool still running when the reply went final is background by construction:\n#{watched}")
    assert_match(/^background: r3 waiting — its result reaches the next turn/, watched, watched)
    refute_match(/^background: r2\b/, watched, "the settled mainline is not background")
    conversation_path = "/agent_api/v1/workspaces/#{@workspace_public_id}/conversations/#{conversation}"
    delivered_usage = agent_api(conversation_path).fetch("conversation").fetch("usage_summary")
    delivered_spend = agent_api("#{loop_path(loop)}/phases").fetch("spend")

    # THE LANE IS BUSY when the receipt lands: a slow turn 2, and the
    # person's word queued behind it (`--mode queue`: a steer would land
    # in turn 2, which is not this case's point).
    busy = CGI.escape(JSON.generate({ "command" => "sleep #{TURN_2_SLEEP}" }))
    said, status = @daemon.cli("say", conversation, "!mock tool_call=bash,bash tool_args=#{busy} echo=content -- ok")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    assert_match(/^queued:\s+\S+ \(pending\)$/, said, "idle, a steer simply queues and starts:\n#{said}")
    started = await_feed(conversation, "turn 2 never started") do |items|
      new_turns(items, except: [loop]).first
    end
    second_loop = started.dig("payload", "run_public_id")
    await_tool_running(second_loop)
    queued, status = @daemon.cli("say", conversation, "!mock echo=content -- what did it find?", "--mode", "queue")
    assert_predicate status, :success?, "rho say --mode queue failed:\n#{queued}"
    word = queued[/^queued:\s+(\S+) \(pending\)$/, 1]
    refute_nil word, "a queued word waits for the turn boundary:\n#{queued}"

    mailed = await_feed(conversation, "the branch's answer was never mailed") do |items|
      items.find { |item| item["type"] == "input_accepted" && item.dig("payload", "origin") == "task_result" }
    end
    assert_equal loop, mailed.dig("payload", "run_public_id")
    assert_equal "r2t0", mailed.dig("payload", "task_key"), "the key the model saw, never the branch's"
    assert_equal %w[direct_reply queue pending], mailed.fetch("payload").values_at("kind", "delivery_mode", "state"),
      "a kernel-stamped queued reply, never a steer: #{mailed.inspect}"
    assert_operator started.fetch("sequence"), :<, mailed.fetch("sequence"),
      "the receipt landed while turn 2 ran — the case's window, not an idle wake"
    completed = await_run_status(loop, "completed")
    refute(completed.fetch("tasks").any? { |task| task.fetch("key").start_with?("w") },
      "no wake round after a final reply: #{summarize(completed)}")
    tip = completed.fetch("tasks").find { |task| task["result_delivered_at"] }
    refute_nil tip, "the tip is stamped once the door accepted it: #{summarize(completed)}"
    assert_equal %w[r3 completed], [tip.fetch("key"), tip.fetch("status")], "the branch's last word is the tip"

    finished = await_feed(conversation, "turn 2 never completed") do |items|
      turn_status(items, status: "completed", loop: second_loop)
    end
    assert_operator mailed.fetch("sequence"), :<, finished.fetch("sequence"), "…and before turn 2 ended"
    refute_includes task_output(second_loop, "r2"), RECEIPT, "the receipt never steered the running turn"

    # THE DRAIN AT TURN 2's BOUNDARY, kernel origin first: two new turns,
    # the receipt's then the person's, each named by its materialization.
    events = await_feed(conversation, "the receipt and the queued word never opened their turns") do |items|
      items if new_turns(items, except: [loop, second_loop]).length >= 2
    end
    woken, personal = new_turns(events, except: [loop, second_loop])
    assert_operator finished.fetch("sequence"), :<, woken.fetch("sequence"), "the drain waited for turn 2's boundary"
    assert_equal mailed.dig("payload", "input_public_id"), materialized(events, woken).dig("payload", "input_public_id"),
      "the FIRST new turn is the kernel's: the receipt drains ahead of the person's earlier word"
    assert_equal word, materialized(events, personal).dig("payload", "input_public_id"), "the SECOND is the person's"
    third_loop = woken.dig("payload", "run_public_id")
    fourth_loop = personal.dig("payload", "run_public_id")
    refute_equal turn, woken.dig("payload", "turn_public_id"), "the wake is a turn of its own"

    await_run_status(third_loop, "completed")
    echoed = task_output(third_loop, "r1")
    assert_includes echoed, RECEIPT, "the woken turn's request carried the receipt as its trailing user text"
    assert_includes echoed, "done: found it", "the branch's answer, inside the envelope"
    refute_includes echoed, "what did it find?", "the person's word was still queued behind it"
    await_run_status(fourth_loop, "completed")
    answered = task_output(fourth_loop, "r1")
    assert_match(/<message from="Owner" kind="ingress" speaker="[^"]+">\nwhat did it find\?\n<\/message>\s*\z/, answered,
      "the person's attributed word is the trailing user text of their own turn")
    assert_operator answered.index(RECEIPT), :<, answered.index("what did it find?"),
      "the woken turn's answer, which carried the receipt, is history ahead of the person's word"
    # DELIVERED ONCE, as the woken turn's seed: the fourth turn's sealed request carries the
    # envelope in exactly one user-role entry — the history's rendering of the woken turn's opening
    # words — and the entry after it is the woken turn's answer.
    sealed = agent_api("#{loop_path(fourth_loop)}/tasks/r1/request").dig("request", "entries")
    refute_nil sealed, "the fourth turn's round one has a sealed request"
    text_parts = sealed.map { |entry| entry.fetch("parts", []).filter_map { |part| part["text"] } }
    refute(text_parts.flatten.any? { |text| text.start_with?("The earlier part of this conversation was summarized") },
      "the case reads an uncompacted history: the fourth turn's request fits the mock's window")
    seed_indexes = sealed.each_index.select do |index|
      sealed[index]["role"] == "user" && text_parts[index].any? { |text| text.include?(RECEIPT) }
    end
    assert_equal 1, seed_indexes.length,
      "the receipt is in the person's turn's history exactly once, as the woken turn's seed: #{text_parts.inspect}"
    assert_equal "assistant", sealed[seed_indexes.first + 1]["role"], "the woken turn's answer follows its seed"

    row = await_follower(conversation, loop: fourth_loop, mailed: true)
    # ONE row, the receipt — the person's three words through rho are `agent`-origin rows with no
    # sender stamp, nobody's mail; the mail names its origin and its speaker beside the sourcing.
    assert_equal [{ "task_key" => "r2t0", "run_public_id" => loop, "origin" => "task_result",
                    "input_public_id" => mailed.dig("payload", "input_public_id"), "sender_conversation_public_id" => conversation }],
      row["delivered_results"].map { |mail| mail.except("authored_by") },
      "the follower read the mail off the feed and keeps it across the turns it woke: #{row["delivered_results"].inspect}"
    assert_equal "agent", row["delivered_results"].dig(0, "authored_by", "kind"), "the receipt's speaker is the agent that posted it"
    watched, status = @daemon.cli("watch", conversation, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
    assert_predicate status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^  delivered\s+r2t0$/, watched, "rho watch prints the mail once, by the key the model saw:\n#{watched}")

    picture, status = @daemon.cli("graph", loop)
    assert_predicate status, :success?, "rho graph failed:\n#{picture}"
    assert_includes picture, "r2t0-model-1", "the orphan is drawn under the loop that started it"
    assert_includes picture, "r3t0", "with the tool it ran after the reply was final"

    # The background continuation still spends on its original loop; all
    # four replies belong to this conversation, including the mailed reply.
    spends = [loop, second_loop, third_loop, fourth_loop].map do |id|
      agent_api("#{loop_path(id)}/phases").fetch("spend")
    end
    usage = agent_api(conversation_path).fetch("conversation").fetch("usage_summary")
    assert_operator spends.first.fetch("input_tokens"), :>, delivered_spend.fetch("input_tokens"),
      "the background model continuation records usage after the original reply was delivered"
    assert_operator usage.fetch("request_count"), :>, delivered_usage.fetch("request_count")
    %w[input_tokens output_tokens cache_read_tokens].each do |counter|
      assert_equal spends.sum { |spend| spend.fetch(counter) }, usage.fetch(counter),
        "conversation #{counter} includes the original background work and every later reply exactly once"
    end
  end

  # THE PERSON CANCELS ONE BRANCH BY THE KEY THE MODEL SAW, after its turn's reply was final: `rho
  # stop <conversation> r2t0` ends the orphan and nothing else. The turn stays `completed`, the
  # mainline is untouched, the branch's rows settle `canceled` WITH a resolution — the one cancel that
  # resolves — and the kernel mails `status="canceled"`, and the canceled receipt WAKES a turn by
  # itself: nobody says anything, the next turn is the kernel's and reads the cancel. THEN THE WAKE
  # IS LEVEL-TRIGGERED: a woken turn with nothing to do ends, wakes nothing, and leaves the queue
  # empty — pinned by a bounded silence on the feed.
  def test_a_person_cancels_one_background_branch_and_the_canceled_receipt_wakes_the_next_turn
    project = connect!
    slow = CGI.escape(JSON.generate({ "command" => "sleep #{STOPPED_SLEEP}" }))
    brief = "!mock tool_call=bash tool_args=#{slow} -- never"
    arguments = CGI.escape(JSON.generate({ "prompt" => brief }))
    conversation, _turn, loop = open_turn("!mock tool_call=delegate_task tool_args=#{arguments} -- answer", project)

    await_feed(conversation, "the turn never completed on the conversation feed") do |items|
      turn_status(items, status: "completed", loop: loop)
    end
    await("the branch's slow tool never started", every: LOOP_POLL) do
      loop_row(loop).fetch("tasks").find { |task| task["key"] == "r3t0" && %w[dispatched running].include?(task["status"]) }
    end

    stopped, status = @daemon.cli("stop", conversation, "r2t0")
    assert_predicate status, :success?, "rho stop failed:\n#{stopped}"
    assert_match(/^stopped:\s+r2t0 \(task\)$/, stopped,
      "one branch, named as a task, on the conversation's backing loop:\n#{stopped}")

    completed = await_run_status(loop, "completed")
    tasks = completed.fetch("tasks").to_h { |task| [task.fetch("key"), task] }
    assert_equal %w[completed completed], [tasks.fetch("r1").fetch("status"), tasks.fetch("r2").fetch("status")],
      "the mainline is untouched: #{summarize(completed)}"
    assert_equal %w[canceled canceled], [tasks.fetch("r3t0").fetch("status"), tasks.fetch("r3").fetch("status")],
      "the branch's fan and continuation are canceled: #{summarize(completed)}"
    assert_equal "canceled", tasks.fetch("r3").fetch("failure_resolution"), "a person's cancel resolves"
    assert_equal "task_canceled", tasks.fetch("r3").dig("error", "key")
    # The mail is a job of its own after quiescence (Runs::ResultDeliveryJob),
    # so the stamp lands AFTER the loop's status settled: awaited, never
    # read off the status snapshot.
    await("the canceled tip was never mailed once the reply was final", every: LOOP_POLL) do
      loop_row(loop).fetch("tasks").find { |task| task["key"] == "r3" && task["result_delivered_at"] }
    end
    refute turn_status(feed(conversation), status: "canceled", loop: loop), "the turn's word stays final"

    # THE WAKE: no `rho say` — the receipt opens the next turn on its own.
    events = await_feed(conversation, "the canceled receipt never woke a turn") do |items|
      items if new_turns(items, except: [loop]).any?
    end
    woken = new_turns(events, except: [loop]).first
    mailed = events.find { |item| item["type"] == "input_accepted" && item.dig("payload", "origin") == "task_result" }
    refute_nil mailed, "no receipt on the feed: #{types(events)}"
    assert_equal mailed.dig("payload", "input_public_id"), materialized(events, woken).dig("payload", "input_public_id"),
      "the woken turn is the receipt's own"
    second_loop = woken.dig("payload", "run_public_id")
    await_run_status(second_loop, "completed")
    echoed = task_output(second_loop, "r1")
    assert_includes echoed, "<task_result task=\"r2t0\" status=\"canceled\">", "the woken turn read the cancel as mail"
    assert_includes echoed, "(task canceled by the person)", "in words the model can act on"

    # LEVEL-TRIGGERED: the woken turn spoke and ended; nothing wakes again.
    settled = await_feed(conversation, "the woken turn never completed") do |items|
      turn_status(items, status: "completed", loop: second_loop)
    end
    sleep SILENCE_SECONDS
    later = feed(conversation).select { |item| item.fetch("sequence") > settled.fetch("sequence") }
    assert_empty later.select { |item| %w[turn_status input_accepted input_materialized].include?(item["type"]) },
      "a woken turn with nothing to do ends and wakes nothing: #{types(later)}"
    assert_empty inputs(conversation), "the queue is empty once the receipt was read"
  end
end
