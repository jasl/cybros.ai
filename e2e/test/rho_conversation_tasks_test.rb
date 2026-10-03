require_relative "rho_conversation_test"

class RhoConversationTest
  # A BACKGROUND TASK OUTLIVES ITS TURN, ITS RECEIPT WAKES THE NEXT TURN, AND THE PERSON'S EARLIER
  # WORD READS AFTER IT. `task` runs detached by DEFAULT: the call answers at once and the reply is
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
  # whole input, and turn 1's `task` call is one already. THE HARNESS FACT: the seed puts each
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
    conversation, turn, loop = open_turn("!mock tool_call=task tool_args=#{arguments} reply=answered -- answer", project)

    await_feed(conversation, "the turn never completed on the conversation feed") do |items|
      turn_status(items, status: "completed", loop: loop)
    end
    watched, status = @daemon.cli("watch", loop, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
    assert_predicate status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^status:\s+completed$/, watched, watched)
    assert_match(/^background: r3t0 (running|dispatched) — its result reaches the next turn; rho watch #{Regexp.escape(loop)} follows$/,
      watched, "the branch's slow tool still running when the reply went final is background by construction:\n#{watched}")
    assert_match(/^background: r3 waiting — its result reaches the next turn/, watched, watched)
    refute_match(/^background: r2\b/, watched, "the settled spine is not background")

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
    second_loop = started.dig("payload", "agent_loop_public_id")
    await_tool_running(second_loop)
    queued, status = @daemon.cli("say", conversation, "!mock echo=content -- what did it find?", "--mode", "queue")
    assert_predicate status, :success?, "rho say --mode queue failed:\n#{queued}"
    word = queued[/^queued:\s+(\S+) \(pending\)$/, 1]
    refute_nil word, "a queued word waits for the turn boundary:\n#{queued}"

    mailed = await_feed(conversation, "the branch's answer was never mailed") do |items|
      items.find { |item| item["type"] == "input_accepted" && item.dig("payload", "origin") == "task_result" }
    end
    assert_equal loop, mailed.dig("payload", "agent_loop_public_id")
    assert_equal "r2t0", mailed.dig("payload", "task_key"), "the key the model saw, never the branch's"
    assert_equal %w[direct_reply queue pending], mailed.fetch("payload").values_at("kind", "delivery_mode", "state"),
      "a kernel-stamped queued reply, never a steer: #{mailed.inspect}"
    assert_operator started.fetch("sequence"), :<, mailed.fetch("sequence"),
      "the receipt landed while turn 2 ran — the case's window, not an idle wake"
    completed = await_loop_status(loop, "completed")
    refute(completed.fetch("tasks").any? { |task| task.fetch("key").start_with?("w") },
      "no wake round after a final reply: #{summarize(completed)}")
    tip = completed.fetch("tasks").find { |task| task["mailed_at"] }
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
    third_loop = woken.dig("payload", "agent_loop_public_id")
    fourth_loop = personal.dig("payload", "agent_loop_public_id")
    refute_equal turn, woken.dig("payload", "turn_public_id"), "the wake is a turn of its own"

    await_loop_status(third_loop, "completed")
    echoed = task_output(third_loop, "r1")
    assert_includes echoed, RECEIPT, "the woken turn's request carried the receipt as its trailing user text"
    assert_includes echoed, "done: found it", "the branch's answer, inside the envelope"
    refute_includes echoed, "what did it find?", "the person's word was still queued behind it"
    await_loop_status(fourth_loop, "completed")
    answered = task_output(fourth_loop, "r1")
    assert_match(/what did it find\?\s*\z/, answered, "the person's word is the trailing user text of their own turn")
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
    assert_equal [{ "task_key" => "r2t0", "agent_loop_public_id" => loop, "origin" => "task_result",
                    "input_public_id" => mailed.dig("payload", "input_public_id"), "sender_conversation_public_id" => conversation }],
      row["mailed"].map { |mail| mail.except("authored_by") },
      "the follower read the mail off the feed and keeps it across the turns it woke: #{row["mailed"].inspect}"
    assert_equal "agent", row["mailed"].dig(0, "authored_by", "kind"), "the receipt's speaker is the agent that posted it"
    watched, status = @daemon.cli("watch", conversation, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
    assert_predicate status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^  mailed\s+r2t0$/, watched, "rho watch prints the mail once, by the key the model saw:\n#{watched}")

    picture, status = @daemon.cli("graph", loop)
    assert_predicate status, :success?, "rho graph failed:\n#{picture}"
    assert_includes picture, "r2t0-model-1", "the orphan is drawn under the loop that started it"
    assert_includes picture, "r3t0", "with the tool it ran after the reply was final"
  end

  # THE PERSON CANCELS ONE BRANCH BY THE KEY THE MODEL SAW, after its turn's reply was final: `rho
  # stop <conversation> r2t0` ends the orphan and nothing else. The turn stays `completed`, the
  # spine is untouched, the branch's rows settle `canceled` WITH a resolution — the one cancel that
  # resolves — and the kernel mails `status="canceled"`, and the canceled receipt WAKES a turn by
  # itself: nobody says anything, the next turn is the kernel's and reads the cancel. THEN THE WAKE
  # IS LEVEL-TRIGGERED: a woken turn with nothing to do ends, wakes nothing, and leaves the queue
  # empty — pinned by a bounded silence on the feed.
  def test_a_person_cancels_one_background_branch_and_the_canceled_receipt_wakes_the_next_turn
    project = connect!
    slow = CGI.escape(JSON.generate({ "command" => "sleep #{STOPPED_SLEEP}" }))
    brief = "!mock tool_call=bash tool_args=#{slow} -- never"
    arguments = CGI.escape(JSON.generate({ "prompt" => brief }))
    conversation, _turn, loop = open_turn("!mock tool_call=task tool_args=#{arguments} -- answer", project)

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

    completed = await_loop_status(loop, "completed")
    tasks = completed.fetch("tasks").to_h { |task| [task.fetch("key"), task] }
    assert_equal %w[completed completed], [tasks.fetch("r1").fetch("status"), tasks.fetch("r2").fetch("status")],
      "the spine is untouched: #{summarize(completed)}"
    assert_equal %w[canceled canceled], [tasks.fetch("r3t0").fetch("status"), tasks.fetch("r3").fetch("status")],
      "the branch's fan and continuation are canceled: #{summarize(completed)}"
    assert_equal "canceled", tasks.fetch("r3").fetch("failure_resolution"), "a person's cancel resolves"
    assert_equal "task_canceled", tasks.fetch("r3").dig("error", "key")
    # The mail is a job of its own after quiescence (AgentLoops::MailJob),
    # so the stamp lands AFTER the loop's status settled: awaited, never
    # read off the status snapshot.
    await("the canceled tip was never mailed once the reply was final", every: LOOP_POLL) do
      loop_row(loop).fetch("tasks").find { |task| task["key"] == "r3" && task["mailed_at"] }
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
    second_loop = woken.dig("payload", "agent_loop_public_id")
    await_loop_status(second_loop, "completed")
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

  # THE COMPOSE SWITCH (compose switch design 2026-09-06, mechanism (B)): the pinned local row
  # `mock-off` says off (the row rung in place of the settings table), so `rho do` names the turn's
  # tools on the input — every declared tool but `compose` — and the declaration is the ONLY gate:
  # the mock, scripted to call `compose` anyway, gets `unknown_tool` at birth and the turn still
  # completes. `rho say` inherits the tier, so the next turn refuses it the same way. `--compose` on
  # a second conversation wins the tier back (the flag beats the table) and the same call is
  # delivered to the kernel's own executor, which authors the script's one tool step. A HARNESS
  # FACT: the call runs DETACHED by default, so the loop settles after the `bash` step and its tip
  # is then mailed and WAKES one more mock turn on that conversation — the woken turn is the
  # daemon's teardown's to end and touches none of these assertions, which read the flagged loop
  # alone.
  def test_the_compose_tier_withholds_the_tool_refuses_a_guessed_call_and_the_flag_wins_it_back
    write_local_row("mock-off", MOCK_OFF_ROW)
    write_settings!("adaptations" => "mock-off")
    project = connect!
    script = CGI.escape(JSON.generate({ "script" => 'g.tool({ name: "bash", input: { command: "echo composed" } });' }))
    prompt = "!mock tool_call=compose tool_args=#{script} -- try compose"

    conversation, _turn, loop, output = open_turn(prompt, project)
    assert_match(/^compose:\s+off \(row mock-off\)\nadaptations:\s+mock-off \(local\)$/, output, output)
    completed = await_loop_status(loop, "completed")
    guessed = compose_call(completed)
    assert_equal %w[failed unknown_tool], [guessed.fetch("status"), guessed.dig("error", "key")],
      "a kernel tool the turn never carried is refused like any other: #{summarize(completed)}"
    assert_equal [guessed.fetch("key")], completed.fetch("tasks").select { |task| task.fetch("status") == "failed" }.map { |task| task.fetch("key") },
      "one bad name never fails a round: #{summarize(completed)}"

    # Turn 2's history renders turn 1's answer, and the mock counts answers
    # across the whole input, so its script must reach a second call.
    said, status = @daemon.cli("say", conversation, "!mock tool_call=compose,compose tool_args=#{script} -- try again")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    second_loop = await_feed(conversation, "the next turn never completed") do |items|
      items.find do |item|
        item["type"] == "turn_status" && item.dig("payload", "status") == "completed" &&
          item.dig("payload", "agent_loop_public_id") != loop
      end&.dig("payload", "agent_loop_public_id")
    end
    inherited = compose_call(await_loop_status(second_loop, "completed"))
    assert_equal %w[failed unknown_tool], [inherited.fetch("status"), inherited.dig("error", "key")],
      "the conversation keeps its tier: `rho say` posted the same subset"

    _conversation, _turn, flagged_loop, output = open_turn(prompt, project, "--compose")
    assert_match(/^compose:\s+on \(flag\)$/, output, output)
    completed = await_loop_status(flagged_loop, "completed")
    assert_equal "completed", compose_call(completed).fetch("status"),
      "the flag wins the tier back and the kernel runs the script: #{summarize(completed)}"
    assert(completed.fetch("tasks").any? { |task| task["tool_name"] == "bash" && task.fetch("status") == "completed" },
      "the script's one tool step was authored and ran here: #{summarize(completed)}")

    # THE THREAD (a compose branch on rows): the compose call is a root — a visible member hangs
    # under it — and its expansion answers no round, because a script's tool step is a call of no
    # round.
    thread = assert_thread_matches_graph!(flagged_loop)
    composed = compose_call(completed).fetch("key")
    assert_equal({ composed => [] }, thread.fetch("branches"),
      "the tool-typed member makes the call a branch with nothing to expand: #{thread.inspect}")
  end

  # A TURN UNDER A LOCAL ADAPTATION ROW: pinned `adaptations: mock` — `tool_style: [claude,
  # workflow]` — the profile declares `Agent` — an ALIAS of the kernel's `task` whose
  # `run_in_background` (default true) is inverted onto the kernel's `wait`, its description the
  # SERVED template with the pack's one recut — and `Workflow` (= `compose`), and no plain `task` or
  # `compose`: the round's sealed `request_options.tools` say so. The row's ONE hint line rides the
  # developer-role lead of the sealed request; `rho do` prints the row after `compose:`. The mock
  # emits whatever name it is told, so this proves the MAPPING and the WIRING, never a model's reach
  # for the name (the bench's, and `live_conversation`'s under the preset): a call made as `Agent`
  # becomes a row under the kernel's wire name with the alias beside it, `run_in_background: false`
  # WAITS (the continuation reads the branch), the default is detached (the `background:` line, the
  # receipt as kernel mail), and the transcript shows what the model called beside what the kernel
  # ran. Two conversations, so the mock's answer count starts at zero for each call.
  def test_a_turn_under_the_claude_preset_calls_agent_and_the_kernel_runs_task
    write_local_row("mock", MOCK_ROW)
    write_settings!("adaptations" => "mock")
    project = connect!

    # The waited branch runs a slow tool so the loop is still working when
    # `--follow` below subscribes: what it prints after the page is then
    # the spine settling, not a page already complete.
    slow = CGI.escape(JSON.generate({ "command" => "sleep #{BRANCH_SLEEP}" }))
    waited_prompt = "!mock tool_call=bash tool_args=#{slow} -- found by the waited branch"
    waited_arguments = CGI.escape(JSON.generate({ "prompt" => waited_prompt, "run_in_background" => false }))
    _conversation, _turn, waited, output = open_turn("!mock tool_call=Agent tool_args=#{waited_arguments} -- answer", project)
    assert_match(/^compose:\s+on \(row mock\)\nadaptations:\s+mock \(local\)$/, output, "the row line after compose:\n#{output}")
    # THE FOLD ON THE CLI: `rho transcript --follow` prints the page, then folds the daemon's stream
    # — the settled `round`/`call` items the follower now relays whole, the kernel's frames —
    # through the SDK's ThreadAccumulator: the `live` line moves when a frame lands, a spine round
    # prints when it SETTLES, a branch's round never prints (the spine law), and the stream's end
    # closes it with the loop.
    followed, status = @daemon.cli("transcript", waited, "--follow", "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
    assert_predicate status, :success?, "rho transcript --follow failed:\n#{followed}"
    lines = followed.lines.map(&:chomp)
    assert_equal "(stream ended: turn_settled)", lines.last, "the follow ends with the loop:\n#{followed}"
    moved = lines.index { |line| line.start_with?("live:") }
    refute_nil moved, "a kernel frame moved the live line after the page:\n#{followed}"
    assert(lines[moved..].any? { |line| line.match?(/\Ar\d+  completed/) },
      "a spine round settled after the page and printed whole:\n#{followed}")
    refute_match(/\(branch\)/, followed, "--follow follows the spine: a branch's round never prints:\n#{followed}")
    completed = await_loop_status(waited, "completed")
    # THE WIRING, off round one's sealed request: the set the model saw is
    # the row's universe — `Agent` and `Workflow` declared, the plain
    # `task`/`compose` never; `Agent`'s text is the served template with the
    # pack's recut (never a copied kernel text); the hint line rides the
    # developer-role lead entry, after the tool lines.
    sealed = agent_api("#{loop_path(waited)}/tasks/r1/request").fetch("request")
    wired = sealed.dig("request_options", "tools").map { |entry| entry.dig("function", "name") }
    assert_includes wired, "Agent"
    assert_includes wired, "Workflow"
    refute_includes wired, "task", "the plain name is withheld under [claude, workflow]"
    refute_includes wired, "compose"
    agent_text = sealed.dig("request_options", "tools").find { |entry| entry.dig("function", "name") == "Agent" }
      .dig("function", "description")
    assert_includes agent_text, "`run_in_background: false` means your next round WAITS for the task", "the pack's recut, rendered at declare"
    refute_includes agent_text, "`wait: true` means your next round WAITS", "the anchor paragraph replaced"
    assert_includes agent_text, "several `Agent` calls in ONE message", "the kernel's macro spelled as the alias"
    developer = sealed.fetch("entries").select { |entry| entry["role"] == "developer" }
      .map { |entry| entry.fetch("parts").map { |part| part["text"].to_s }.join }
    assert(developer.any? { |text| text.end_with?("start_process, never `&`.\n\n#{MOCK_HINT}") },
      "the row's hint rides the developer lead after the tool lines: #{developer.inspect}")
    call = agent_call(completed)
    assert_equal %w[tool_task task Agent completed], call.values_at("kind", "tool_name", "tool_alias", "status"),
      "the row carries the kernel's wire name and the alias the model spelled: #{call.inspect}"
    assert_equal({ "prompt" => waited_prompt, "wait" => true }, tool_input(waited, call.fetch("key")),
      "run_in_background: false maps onto the kernel's wait: true")
    branch = "#{call.fetch("key")}-model-1"
    assert(completed.fetch("tasks").any? { |task| task.fetch("key") != branch && Array(task["after"]).include?(branch) },
      "a later round WAITED on the branch: #{summarize(completed)}; the call settled: #{task_output(waited, call.fetch("key")).inspect}")
    refute(completed.fetch("tasks").any? { |task| task.fetch("key").start_with?("w") }, "nothing to wake: #{summarize(completed)}")
    # THE THREAD (the waited `task` branch on rows): the thread equals the graph's tree — the Agent
    # call a root on the spine's row, the branch's rounds under its expansion — and `rho transcript
    # --prefix` prints that branch: its rows say `(branch)`, and the spine page shows what the model
    # called beside what the kernel ran.
    thread = assert_thread_matches_graph!(waited)
    assert_equal [branch], thread.fetch("branches").fetch(call.fetch("key")).first(1),
      "the branch root is the first row under the call: #{thread.inspect}"
    printed, status = @daemon.cli("transcript", waited)
    assert_predicate status, :success?, printed
    assert_match(/^  - Agent completed/, printed, "the alias the model spelled, on the spine's row:\n#{printed}")
    assert_match(/^  \+1 branch under #{Regexp.escape(call.fetch("key"))}$/, printed, printed)
    expanded, status = @daemon.cli("transcript", waited, "--prefix", call.fetch("key"))
    assert_predicate status, :success?, expanded
    assert_match(/^#{Regexp.escape(branch)} \(branch\)  completed/, expanded, "the root, off the spine:\n#{expanded}")
    refute_match(/^  \+\d+ branch/, expanded, "nothing hangs under a branch that called no kernel tool")
    printed, status = @daemon.cli("task", waited, call.fetch("key"))
    assert_predicate status, :success?, printed
    assert_match(/^tool:      task$/, printed, printed)

    detached_arguments = CGI.escape(JSON.generate({ "prompt" => "!mock tool_call=bash tool_args=#{slow} -- done: detached" }))
    conversation, _turn, detached = open_turn("!mock tool_call=Agent tool_args=#{detached_arguments} -- answer", project)
    await_feed(conversation, "the detached turn never completed") { |items| turn_status(items, status: "completed", loop: detached) }
    watched, status = @daemon.cli("watch", detached, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
    assert_predicate status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^background: \S+ (running|dispatched) — its result reaches the next turn/, watched,
      "run_in_background absent → detached: the branch's slow tool outlives the reply:\n#{watched}")
    # THE KERNEL'S OWN FRAME ON THE CLI: the daemon's ring held the loop's `round_started` from the
    # conversation's progress feed, and `rho watch` prints it under the round's key in the frame
    # column — the model, the sealed size, the attempt.
    assert_match(%r{^  r\d+\s+│ started · dev/mock-text · .+ · attempt 1$}, watched,
      "the round dialled prints as a kernel frame beside the table:\n#{watched}")
    completed = await_loop_status(detached, "completed")
    call = agent_call(completed)
    assert_equal %w[task Agent], call.values_at("tool_name", "tool_alias")
    assert_equal({ "prompt" => "!mock tool_call=bash tool_args=#{slow} -- done: detached" }, tool_input(detached, call.fetch("key")),
      "the default spells no wait at all")
    mailed = await_feed(conversation, "the detached branch's answer was never mailed") do |items|
      items.find { |item| item["type"] == "input_accepted" && item.dig("payload", "origin") == "task_result" }
    end
    assert_equal call.fetch("key"), mailed.dig("payload", "task_key"), "the receipt names the key the model saw"

    # THE THREAD (the detached `task` branch on rows): the branch's own bash round is a loop-global
    # `r<n>` key and reaches the page only under the call's expansion, by its first read.
    thread = assert_thread_matches_graph!(detached)
    under = thread.fetch("branches").fetch(call.fetch("key"))
    assert_equal "#{call.fetch("key")}-model-1", under.first, "the root leads the branch: #{thread.inspect}"
    assert_operator under.length, :>=, 2, "the branch's bash round continues its root under the expansion: #{thread.inspect}"
    assert_empty thread.fetch("spine").map { |row| row["key"] } & under, "a branch's round is never a spine row"
  end
end
