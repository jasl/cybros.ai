require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/compaction_results"
require "support/fs_port_server"
require "support/mcp_fixture/declarations"
require "support/mcp_fixture/host"
require "support/peer_program"
require "support/realtime_lane"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"
require "support/thread_check"

# A CHAT-SHAPED CLIENT WITH ZERO LOOP VERBS: `rho do` opens a conversation and says the prompt on
# it; the kernel materializes each turn into a loop backed by this machine's tools; `rho say` is the
# one verb for the next thing — a steer lands at the running turn's boundary, a queued word waits
# for the turn boundary, and on an idle conversation either simply opens the next turn — and `rho
# stop` cancels the running turn. Driven through the shipped binary on the full default set
# (`retry`, `watch` and `task` are Ops's), against the mock provider, whose ONE property makes the
# assertions possible: it echoes its input, so what a continuation or a later turn was SHOWN is
# readable off its answer.
#
# What is read: the conversation's feed through the steward's member plane,
# the backing loop's trace and task reads (loop-grain, valid on a backing
# loop), and the daemon's own follower row (`GET /followers`, Ops).
#
# SHARED PLUMBING, STATED: every test in this file drives the SAME signed-in
# steward browser (E2E::StewardSession, one per journey process); the
# daemon, its RHO_HOME and every ceremony stay per test.
class RhoConversationTest < Minitest::Test
  include E2E::RealtimeLane
  include E2E::ThreadCheck
  include E2E::CompactionResults

  MODEL = "dev/mock-text".freeze
  ENVELOPE = "<tool_use_error>The tool call was aborted before it completed. (run_canceled)</tool_use_error>".freeze
  # The kernel's receipt for the background task the mail journey starts
  # (`AgentRuns::TaskResultEnvelope`), with the status a started text
  # never carries — the started text names `<task_result task="r2t0">`
  # too, so the status is what tells the receipt from the promise of one.
  RECEIPT = "<task_result task=\"r2t0\" status=\"completed\">".freeze
  # THE MAIL JOURNEY'S WINDOW, off the harness's one hold
  # (`E2E::RhoDaemon::HOLD_SECONDS`): the branch's sleep must END while
  # turn 2 runs — after turn 2 started (`rho watch` then `rho say`, one
  # verb pair, land inside the hold) and before its own sleep ends — or
  # the case degenerates to an idle wake, which its sequence assertions
  # refuse. Turn 2 holds twice as long: the branch's remainder, the mail's
  # landing and a third verb (`rho say --mode queue`) all fall inside it.
  BRANCH_SLEEP = E2E::RhoDaemon::HOLD_SECONDS
  TURN_2_SLEEP = 2 * E2E::RhoDaemon::HOLD_SECONDS
  # A hold a person's verb ENDS (`rho stop`): it never runs out on its own
  # — three holds outlast the verb's landing and the sweep the assertion
  # waits for, so a hold that ended by itself could never read as a kill.
  STOPPED_SLEEP = 3 * E2E::RhoDaemon::HOLD_SECONDS
  # A bounded silence after a woken turn ended: longer than the drain's
  # kick and a mock turn's whole life (both under a second here).
  SILENCE_SECONDS = 6
  # The kernel's own words a compaction leaves in a request:
  # `Conversations::Compaction::REREAD_RULE` (the frame before every summary
  # a model reads) and `Compaction::Serialize::HEADER` (the summarizer's
  # rendering, which the mock echoes as the summary).
  REREAD_RULE = "This summary replaces earlier history and carries no data values: " \
    "re-read any file, output or result it mentions before you use it.".freeze
  COMPACTION_HEADER = "Here is the transcript to compact.".freeze
  # Local adaptation rows exercise loading and wiring through the real daemon. `mock` aliases
  # task to Agent, adds one developer-role hint, and supplies a custom
  # summarizer prompt. The declaration stores that prompt in the profile's summarizer slot, and
  # a compaction round seals it as instructions. These fixture texts are independent of
  # the current paid candidates.
  MOCK_HINT = "A task you start without `wait: true` answers later, in a message that is not from the " \
    "person; do not wait for it, poll it, or re-run its command yourself.".freeze
  MOCK_SUMMARIZER = "Compact this transcript for the mock: name every file and result as a pointer, never its " \
    "value, and end on the next action.".freeze
  MOCK_ROW = <<~YAML.freeze
    format: 1
    row: mock
    models: []
    tool_style: [claude]
    tool_descriptions: []
    summarizer_prompt: "#{MOCK_SUMMARIZER}"
    lead_hints:
      - id: mock-hint
        text: "#{MOCK_HINT}"
  YAML

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-conversation-e2e")
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    sign_in_steward
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(File.join(@home, "log", "rho.log"), "rho structured log") if @home
      warn_log(@mcp_fixture_log, "http mcp fixture")
      %i[runner jobs].each do |host|
        warn_log(E2E.hosts.log_path(host), "nexus #{host}")
      rescue StandardError
        nil
      end
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/rho_conversation-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture rho conversation E2E capture: #{error.class}: #{error.message}"
  ensure
    restore_answered_workspace
    if (result = @daemon&.dispose_connection)
      output, status = result
      assert_predicate status, :success?, output
    end
    Array(@fs_servers).each(&:stop)
    E2E::McpFixture::Host.stop(@mcp_fixture_pid) if @mcp_fixture_pid
    [@home, @project, *Array(@bound_directories), *Array(@mirrors)].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  # THE DAEMON'S MATERIALIZATION BOUND (`Rho::Daemon::Loops::MATERIALIZATION_WAIT`),
  # named here rather than loaded: a `pending` answer costs exactly this
  # long at the terminal, and a blocked input must cost nothing like it.
  MATERIALIZATION_WAIT = 30

  # AN INPUT THE KERNEL BLOCKS IS A REFUSAL AT THE TERMINAL, NOT A PENDING
  # TURN: an unknown model makes the drain park the input `blocked`
  # (`unknown_model`) and narrate `input_blocked` on the conversation's
  # feed before any model round; the daemon's follower reads it off that
  # feed and `rho do` prints the kernel's reason word with exit 1 the
  # moment it lands — never the 30 s bound a slow kernel would cost. The
  # conversation stands with the input parked, named in the sentence.
  def test_an_input_the_kernel_blocks_is_a_refusal_at_the_terminal_not_a_pending_turn
    project = connect!

    began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    output, status = @daemon.cli("do", "say hi", "--model", "dev/no-such-model", "--dir", project)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - began

    refute_predicate status, :success?, "rho do exited 0 on a blocked input:\n#{output}"
    assert_match(/^rho do: the kernel blocked the input \(unknown_model\)/, output, output)
    refute_match(/^pending:/, output, output)
    assert_operator elapsed, :<, MATERIALIZATION_WAIT, "the terminal was held for the bound (#{elapsed.round(1)} s)"

    conversation = output[/the conversation (\S+) stands/, 1]
    refute_nil conversation, "the refusal names the conversation the input is parked on:\n#{output}"
    blocked = feed(conversation).select { |item| item["type"] == "input_blocked" }
    assert_equal ["unknown_model"], blocked.map { |item| item.dig("payload", "blocked_reason") },
      "the feed's sole input_blocked is the kernel's own word"
    parked = inputs(conversation)
    assert_equal [%w[blocked unknown_model]], parked.map { |input| [input["state"], input["blocked_reason"]] },
      "the input stands parked on the conversation: #{parked.inspect}"
  end

  # ITEM 1: a coding turn with tools, through the conversation door. The turn's status rides the
  # conversation feed with the backing loop's id on it; the loop's own task items ride the SAME
  # feed; the tool ran here. Then THE TRANSCRIPT STREAM, cross-process: the next turn's round
  # settles in the jobs host and its snapshot lands on the CONVERSATION's transcript — never on a
  # loop address no channel serves for a loop-backed loop — where a subscriber attached to Puma
  # reads it before the turn's own. The conversation `rho do` opens does not exist to be subscribed
  # to until it prints, so the pin rides the turn `rho say` opens on it. Snapshots are published
  # after commit by whichever host settles the node and are deterministic; deltas stay unasserted —
  # the two model hosts race for them (conversation_turn_test).
  def test_a_chat_shaped_client_runs_a_coding_turn_with_tools
    project = connect!
    note = File.join(project, "note.txt")
    arguments = CGI.escape(JSON.generate({ "path" => note, "content" => "hello from the conversation\n" }))
    conversation, turn, loop = open_turn("!mock tool_call=write tool_args=#{arguments} -- write the note and say so", project)

    completed = await_run_status(loop, "completed")
    tool_task = completed.fetch("tasks").find { |task| task.fetch("kind") == "tool_task" }
    refute_nil tool_task, "the model never called a tool: #{summarize(completed)}"
    assert_equal "write", tool_task.fetch("tool_name")
    assert_equal "completed", tool_task.fetch("status"), tool_task.inspect
    assert_equal "hello from the conversation\n", File.read(note, encoding: Encoding::UTF_8),
      "the runner wrote the file the model asked for"

    events = await_feed(conversation, "the turn never completed on the conversation feed") do |items|
      items if turn_status(items, status: "completed", loop: loop)
    end
    running = turn_status(events, status: "running", loop: loop)
    refute_nil running, "no turn_status{running} named the backing loop: #{types(events)}"
    assert_equal turn, running.dig("payload", "turn_public_id")
    assert_equal turn, turn_status(events, status: "completed", loop: loop).dig("payload", "turn_public_id")
    assert(events.any? { |item| item["type"] == "task_status" && item.dig("payload", "task_key") == "r1" },
      "the loop's own task items ride the conversation's feed: #{types(events)}")
    assert(events.any? { |item| item["type"] == "turn_status" && item.dig("payload", "run_status") },
      "the loop's state notes ride the conversation's feed: #{types(events)}")

    row = await_follower(conversation, loop: loop)
    assert_equal "completed", row.fetch("status"), row.inspect

    items = with_reactor do
      subscription = subscribe_to_transcript(conversation,
        workspace_public_id: @workspace_public_id, credential: @steward.member_token)
      said, status = @daemon.cli("say", conversation, "!mock -- and say it once more")
      assert_predicate status, :success?, "rho say failed:\n#{said}"
      drain_until(subscription, "turn", timeout: AWAIT_SECONDS)
    end
    round = items.find { |item| item["type"] == "round" }
    refute_nil round, "no round settled on the conversation's transcript: #{types(items)}"
    assert_equal "r1", round.fetch("task_key")
    assert_equal "r1", round.dig("round", "task_key"), "the snapshot is the transcript's own row"
    assert_equal "completed", round.dig("round", "status")
    second_loop = round.fetch("run_public_id")
    refute_equal loop, second_loop, "the next turn is backed by its own loop"
    settled = items.last
    assert_equal "turn", settled.fetch("type"), types(items)
    assert_equal round.fetch("turn_public_id"), settled.fetch("turn_public_id"),
      "one routing key for both kinds of item: the round named the turn through the seam"
    assert_equal "completed", settled.dig("turn", "status")
    assert_equal second_loop, settled.dig("turn", "active_variant", "run_public_id")
    assert_equal ["r1"], settled.dig("turn", "active_variant", "rounds").map { |row| row["task_key"] },
      "the turn's snapshot carries the loop's rounds"
    assert_equal second_loop, await_feed(conversation, "the next turn never completed on the feed") { |feed|
      turn_status(feed, status: "completed", loop: second_loop)&.dig("payload", "run_public_id")
    }, "the stream named the loop the feed names"
  end

  # ITEM 2 and ITEM 3, one slow tool apart. Round 1 calls `sleep`, which is
  # the window both words go in: the STEER — sent by the LOOP id, the paid
  # lanes' spelling, resolved through the store row — lands in the
  # continuation's sealed request and the mock's echo carries it; the
  # QUEUED word waits, drains at the turn boundary into a NEW turn whose
  # history renders turn 1's rounds. The bare `!mock --` on the queued word
  # is what keeps turn 1's script from being re-read by turn 2.
  def test_a_steer_lands_in_the_continuation_and_a_queued_word_drains_at_the_boundary
    project = connect!
    arguments = CGI.escape(JSON.generate({ "command" => "sleep 12" }))
    conversation, turn, loop = open_turn("!mock tool_call=bash tool_args=#{arguments} -- wait, then report", project)
    await_tool_running(loop)

    said, status = @daemon.cli("say", loop, "also print the sum")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    assert_match(/^queued:\s+\S+ \(steering\)$/, said, "a steer binds to the running turn:\n#{said}")
    queued, status = @daemon.cli("say", conversation, "!mock -- and one more thing", "--mode", "queue")
    assert_predicate status, :success?, "rho say --mode queue failed:\n#{queued}"
    assert_match(/^queued:\s+\S+ \(pending\)$/, queued, "a queued word waits for the turn boundary:\n#{queued}")

    await_run_status(loop, "completed")
    events = await_feed(conversation, "the steer never landed") do |items|
      items if items.any? { |item| item["type"] == "input_materialized" && item.dig("payload", "task_key") }
    end
    landed = events.find { |item| item["type"] == "input_materialized" && item.dig("payload", "task_key") }
    assert_equal loop, landed.dig("payload", "run_public_id")
    assert_equal turn, landed.dig("payload", "turn_public_id")
    refute_equal "r1", landed.dig("payload", "task_key"),
      "the steer landed in the continuation, never in the round already on the wire"
    assert_includes task_output(loop, landed.dig("payload", "task_key")), "also print the sum",
      "the continuation's sealed request carried the steer"

    # THE TURN BOUNDARY: completed, then the drain, then the next turn on a
    # loop of its own.
    events = await_feed(conversation, "the queued word never opened the next turn") do |items|
      items if items.any? { |item| item["type"] == "turn_status" && item.dig("payload", "status") == "running" && item.dig("payload", "run_public_id") != loop }
    end
    settled = turn_status(events, status: "completed", loop: loop)
    opened = events.find { |item| item["type"] == "turn_status" && item.dig("payload", "status") == "running" && item.dig("payload", "run_public_id") != loop }
    second_loop = opened.dig("payload", "run_public_id")
    refute_nil second_loop, opened.inspect
    drained = events.find { |item| item["type"] == "input_materialized" && item.dig("payload", "turn_public_id") == opened.dig("payload", "turn_public_id") }
    refute_nil drained, "no materialization named the second turn: #{types(events)}"
    assert_operator settled.fetch("sequence"), :<, drained.fetch("sequence"), "the drain waited for the boundary"
    assert_operator drained.fetch("sequence"), :<, opened.fetch("sequence")

    await_run_status(second_loop, "completed")
    echoed = task_output(second_loop, "r1")
    assert_includes echoed, "wait, then report", "turn 2's history carried turn 1's rounds"
    assert_includes echoed, "and one more thing", "turn 2's request carried the queued word"

    row = await_follower(conversation, loop: second_loop)
    assert_equal "completed", row.fetch("status"), row.inspect
  end

  # THE KERNEL COMPACTS ON THE PROVIDER'S OWN COUNT. Round 1 calls bash and reports 9 000
  # input tokens against the dev model's 8 192 window. Round 2 reads the summary followed by
  # the new result's first consumption. The summary itself carries only the result pointer.
  # THE SUMMARIZER SLOT: the home pins the `mock` row, so rho wrote its `summarizer_prompt`
  # into the profile's `summarizer` slot at declare, and `k1`'s sealed
  # `request_options.instructions` are those bytes — the kernel read the slot, not its default text.
  def test_a_round_whose_reported_usage_fills_the_window_is_compacted_once_and_the_summary_carries_pointers
    write_local_row("mock", MOCK_ROW)
    # THE HOME'S OWN FILE names rho-dev beside the row (a written file is used verbatim, never
    # merged by the fixture).
    write_settings!("adaptations" => "mock")
    project = connect!
    marker = "first-line-#{SecureRandom.hex(6)}"
    prompt = compaction_prompt(project, marker)
    conversation, turn, loop = open_turn(prompt, project)

    completed = await_run_status(loop, "completed")
    tasks = completed.fetch("tasks").to_h { |task| [task.fetch("key"), task] }
    assert_equal %w[completed completed], [tasks.fetch("r1").fetch("status"), tasks.fetch("r2").fetch("status")],
      "the round and its continuation both settled: #{summarize(completed)}"
    summarizer = tasks.fetch("k1") { flunk "no summarizer on the trace: #{summarize(completed)}" }
    assert_equal %w[model_task completed collapsed],
      [summarizer.fetch("kind"), summarizer.fetch("status"), summarizer.fetch("visibility")], summarizer.inspect
    tool_task = tasks.values.find { |task| task.fetch("kind") == "tool_task" } || flunk("the model never called a tool: #{summarize(completed)}")
    assert_equal %w[bash completed], [tool_task.fetch("tool_name"), tool_task.fetch("status")], tool_task.inspect
    assert_includes tool_result(loop, tool_task.fetch("key")), marker, "the tool's result carried the marker"

    compactions = feed(conversation).select { |item| item["type"] == "context_compacted" }
    assert_equal 1, compactions.size, "exactly one repair on one wall: #{compactions.map { |c| c["payload"] }.inspect}"
    variant = steward_client.workspace(@workspace_public_id).conversation(conversation).turns.variants(turn)
      .find { |candidate| candidate.run_public_id == loop } || flunk("the turn has no variant backed by #{loop}")
    assert_equal({ "mode" => "kernel", "trigger" => "usage", "task_key" => "r2", "summary_task_key" => "k1",
                   "run_public_id" => loop, "turn_public_id" => turn,
                   "variant_public_id" => variant.public_id }, compactions.first.fetch("payload"))

    summary = task_output(loop, "k1")
    assert_includes summary, COMPACTION_HEADER, "the summarizer read the kernel's rendering"
    assert_includes summary, "Tool bash (completed, ok)", "and the call, as a pointer"
    assert_includes summary, "not carried"
    refute_includes summary, marker, "a summary carries pointers, never the result's value"
    sealed = agent_api("#{loop_path(loop)}/tasks/k1/request").fetch("request")
    assert_equal MOCK_SUMMARIZER, sealed.dig("request_options", "instructions"),
      "the slot's bytes are the summarizer's instructions: rho wrote the row's text, the kernel read it"
    declared = @daemon.log_lines.find { |line| line["event"] == "profile.declared" }
    assert_equal "written", declared && declared["summarizer"], "rho wrote the slot beside the guideline: #{declared.inspect}"
    continued = task_output(loop, "r2")
    assert_includes continued, REREAD_RULE, "the kernel's frame leads the repaired round's request"
    assert_includes continued, COMPACTION_HEADER, "and the summary follows it, in place of the history"
    assert_equal 1, continued.scan(marker).length, "the new result is consumed exactly once after the summary"
    assert_compaction_result_request(loop, marker)

    # THE THREAD: the kernel's summarizer `k1` is on no page — off the mainline, under no call — and
    # the round it repaired carries the cut on its own row.
    thread = assert_thread_matches_graph!(loop)
    refute_includes thread.fetch("mainline").map { |row| row["key"] }, "k1", "a summarizer is not the conversation"
    assert_empty thread.fetch("branches"), "nothing hangs under a bash call"
    repaired = agent_api("#{loop_path(loop)}/transcript").fetch("rounds").find { |row| row["task_key"] == "r2" }
    assert_equal "r2", repaired.fetch("compacted_before"), "the reader draws the cut from the round that read the summary"
  end

  # A scripted non-retryable 400 fails the materialized `r1`
  # (`on_failure: halt`) without waiting through transport backoff: the turn reads `failed` with the
  # hold's reason; `rho watch` says it is holding; `rho retry` REOPENS the
  # same turn (the level goes back to `running`) and the mock halts it
  # again; then the person's next word — typed AFTER the hold — is not
  # blocked behind it: it opens a NEW turn on a new loop, and the held
  # loop is canceled as `replaced`.
  def test_a_halted_turn_is_repaired_from_the_terminal_and_the_next_word_replaces_it
    project = connect!
    conversation, turn, loop = open_turn("!mock error=400 -- break", project)

    events = await_feed(conversation, "the turn never halted") do |items|
      items if turn_status(items, status: "failed", loop: loop)
    end
    halted = turn_status(events, status: "failed", loop: loop)
    assert_equal "halt_failure", halted.dig("payload", "failure_reason_key"), halted.inspect
    assert_equal turn, halted.dig("payload", "turn_public_id")
    refute_nil halted.dig("payload", "error_key"), "a hold names the newest failure: #{halted.inspect}"
    assert_equal ["r1"], halted.dig("payload", "blocked_task_keys"), halted.inspect

    watched, status = @daemon.cli("watch", loop, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
    assert_predicate status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^status:\s+failed$/, watched, watched)
    assert_match(/^holding:\s+`rho retry #{Regexp.escape(loop)}`/, watched, watched)

    retried, status = @daemon.cli("retry", loop)
    assert_predicate status, :success?, "rho retry failed:\n#{retried}"
    assert_match(/^retried:\s+r1$/, retried, retried)
    events = await_feed(conversation, "the retry never reopened and re-halted the turn") do |items|
      later = items.select { |item| item.fetch("sequence") > halted.fetch("sequence") }
      items if turn_status(later, status: "running", loop: loop) && turn_status(later, status: "failed", loop: loop)
    end
    later = events.select { |item| item.fetch("sequence") > halted.fetch("sequence") }
    reopened = turn_status(later, status: "running", loop: loop)
    assert_equal turn, reopened.dig("payload", "turn_public_id"), "a retry reopens the SAME turn"
    assert_equal "halt_failure", turn_status(later, status: "failed", loop: loop).dig("payload", "failure_reason_key")

    said, status = @daemon.cli("say", conversation, "!mock -- carry on")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    assert_match(/^queued:\s+\S+ \(pending\)$/, said, "idle, a steer simply queues and starts:\n#{said}")
    events = await_feed(conversation, "the next word never opened a turn past the hold") do |items|
      items if items.any? { |item| item["type"] == "turn_status" && item.dig("payload", "status") == "completed" && item.dig("payload", "run_public_id") != loop }
    end
    opened = events.find { |item| item["type"] == "turn_status" && item.dig("payload", "status") == "running" && item.dig("payload", "run_public_id") != loop }
    refute_nil opened, "no second turn started: #{types(events)}"
    refute_equal turn, opened.dig("payload", "turn_public_id")
    replaced = await_feed(conversation, "the held loop was never canceled as replaced") do |items|
      items.find do |item|
        item["type"] == "turn_status" && item.dig("payload", "run_public_id") == loop &&
          item.dig("payload", "failure_reason") == "replaced"
      end
    end
    assert_includes %w[canceling canceled], replaced.dig("payload", "run_status"), replaced.inspect
    refute(events.any? { |item| item["type"] == "input_blocked" && item.dig("payload", "blocked_reason") == "run_held" },
      "the person's own word, typed after the hold, is never blocked behind it: #{types(events)}")
  end

  # Cancel a turn while a tool process is running. The kernel settles the tool as canceled before
  # notifying the claimant; the runner kills the process group, and its later result cannot
  # overwrite terminal state. The following turn must see a kernel-authored error envelope paired
  # with the canceled call, so history contains no dangling tool request.
  def test_a_canceled_turns_dangling_call_reaches_the_next_turn_as_an_envelope_and_the_runners_group_is_dead_within_one_sweep
    project = connect!
    pgid_path = File.join(project, "pgid")
    arguments = CGI.escape(JSON.generate({ "command" => "ps -o pgid= -p $$ | tr -d ' ' > #{pgid_path}; sleep #{STOPPED_SLEEP}" }))
    conversation, _turn, loop = open_turn("!mock tool_call=bash tool_args=#{arguments} -- wait", project)
    await_tool_running(loop)
    pgid = await("the shell never wrote its process group", every: 0.2) do
      File.file?(pgid_path) ? File.read(pgid_path).strip[/\A\d+\z/] : nil
    end.to_i
    assert process_group_alive?(pgid), "the shell's group is live while the tool runs"

    stopped, status = @daemon.cli("stop", conversation)
    assert_predicate status, :success?, "rho stop failed:\n#{stopped}"
    assert_match(/^stopped:\s+#{Regexp.escape(conversation)} \(conversation\)$/, stopped,
      "conversation stop cancels its current and background work:\n#{stopped}")
    assert await_process_group_gone(pgid, within: GROUP_DEAD_SECONDS),
      "the runner's `work_canceled` kill did not end the shell's group #{pgid} within one sweep"
    await_feed(conversation, "the canceled turn never settled") do |items|
      turn_status(items, status: "canceled", loop: loop)
    end
    canceled = await_run_status(loop, "canceled")
    tool_task = canceled.fetch("tasks").find { |task| task.fetch("kind") == "tool_task" }
    assert_equal "canceled", tool_task.fetch("status"), summarize(canceled)
    assert_equal "run_canceled", tool_task.dig("error", "key"), tool_task.inspect

    meters, status = @daemon.cli("runner")
    assert_predicate status, :success?, meters
    assert_match(/^claimed:.*\bcanceled: 1\b/, meters, "the cancel frame reached the in-flight context once:\n#{meters}")
    refute_match(/runner_submit_refused|runner_task_failed/, rho_log,
      "the runner's answer after the cancel is idle kernel-side — never refused, never a failure")

    said, status = @daemon.cli("say", conversation, "!mock -- what happened")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    events = await_feed(conversation, "the next turn never completed") do |items|
      items if items.any? { |item| item["type"] == "turn_status" && item.dig("payload", "status") == "completed" && item.dig("payload", "run_public_id") != loop }
    end
    second_loop = events.find { |item| item["type"] == "turn_status" && item.dig("payload", "status") == "completed" && item.dig("payload", "run_public_id") != loop }
      .dig("payload", "run_public_id")
    assert_includes task_output(second_loop, "r1"), ENVELOPE,
      "turn 2's history rendered turn 1's dangling call with the kernel's envelope"
  end

  # THE ANSWERING PROFILE IS A STORED FACT. A person opens a conversation through the member plane
  # in a PLAIN workspace of their own (rho's adopted workspace is dedicated to rho, so a second
  # program would be fenced there) and names rho's profile as the ANSWERER and rho's runner as the
  # binding — both read off `rho status`. The person's own head runs under rho's engine on rho's
  # runner: a `write` lands on this machine and the reply reads `agent_run`. Before the column a
  # Human's conversation had no engine — the same head was `inference` — and that is the
  # discriminator. Then a SECOND agent program, paired through the steward's own session and
  # declaring nothing, posts a note and asks: its ask is answered by rho's engine too (under the old
  # rule the poster's nil declaration made it a plain reply — the hijack's inverse), the engine read
  # the note, and the answerer never moved. Last, the person's fork keeps the answerer: the forker
  # is a Human, the child still answers as its source — a silent default would have made the forker
  # the answerer and the child a plain chat.
  def test_a_person_opens_a_conversation_answered_by_the_agent_a_peers_post_is_a_speaker_and_a_fork_keeps_the_answerer
    project = connect!
    rho_profile, rho_runner = rho_identity
    client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    workspace = client.workspaces.create(name: "Answered #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid)
    @answered_workspace = [client, workspace.public_id]
    conversations = client.workspace(workspace.public_id).conversations
    created = conversations.create(
      idempotency_key: SecureRandom.uuid,
      answering_user_public_id: rho_profile, default_runner_executor_public_id: rho_runner
    )
    assert_equal rho_profile, created.conversation.answering_user_public_id, "the create answers the stored fact"
    assert_equal rho_runner, created.conversation.default_runner.executor_public_id,
      "rho's private runner binds a Human's conversation: the binding is judged for the ANSWERER"
    chat = conversations.conversation(created.public_id)

    # The person's head: rho's declaration chooses the engine, rho's runner
    # serves the call from a workspace it never adopted.
    note = File.join(project, "answered-note.txt")
    arguments = CGI.escape(JSON.generate({ "path" => note, "content" => "hello from the answered conversation\n" }))
    reply = ask(chat, "!mock tool_call=write tool_args=#{arguments} -- write the note and say so")
    assert_equal "run", reply.active_variant.source,
      "a Human's head on a conversation answered by rho runs under rho's engine: #{reply.to_h.inspect}"
    loop_id = reply.active_variant.run_public_id
    completed = await_run_status_in(client, workspace.public_id, loop_id, "completed")
    tool_task = completed.tasks.find { |task| task.kind == "tool_task" }
    refute_nil tool_task, "the model never called a tool: #{completed.tasks.map(&:to_h).inspect}"
    assert_equal %w[write completed], [tool_task.tool_name, tool_task.status], tool_task.to_h.inspect
    assert_equal "hello from the answered conversation\n", File.read(note, encoding: Encoding::UTF_8),
      "rho's runner wrote the file rho's engine asked for"

    # The peer: a speaker, never an engine.
    peer = pair_peer_program
    peer_chat = peer.workspace(workspace.public_id).conversations.conversation(created.public_id)
    peer_note = "a peer's note #{SecureRandom.hex(4)}"
    peer_chat.inputs.create(kind: "message", text: peer_note, idempotency_key: SecureRandom.uuid)
    peer_reply = ask(peer_chat, "!mock -- the peer asks")
    noted = chat.turns.list.items.find { |turn| turn.kind == "message" && turn.text == peer_note }
    refute_nil noted, "the peer's note never landed on the timeline: #{chat.turns.list.items.map(&:to_h).inspect}"
    assert_equal "user", noted.role
    assert_equal "run", peer_reply.active_variant.source,
      "a peer that declares nothing is answered by the conversation's engine, never its own: #{peer_reply.to_h.inspect}"
    peer_loop = peer_reply.active_variant.run_public_id
    refute_equal loop_id, peer_loop, "the peer's turn is backed by a loop of its own"
    assert_equal "completed", await_run_status_in(client, workspace.public_id, peer_loop, "completed").status
    assert_includes peer_reply.text, peer_note, "rho's engine read the peer's words as this conversation's history"
    assert_equal rho_profile, chat.fetch.answering_user_public_id, "the answerer never moved"

    # The fork.
    forked = chat.fork(turn_public_id: reply.public_id, idempotency_key: SecureRandom.uuid)
    refute_equal created.public_id, forked.conversation.public_id
    assert_equal rho_profile, forked.conversation.answering_user_public_id,
      "the forker is a Human; the child still answers as its source"
  end

  # THE PROMPTLESS OPEN AND WHAT `say` ANSWERS. `rho do` with no PROMPT opens the conversation and
  # nothing else: the daemon's row follows it with no Run, the feed carries no turn, the queue is
  # empty. The first `rho say` opens the turn and PRINTS its ids — `turn:`/`run:` after the queued
  # row, the Run the kernel minted for THESE words (a reader joining on the input alone read the
  # previous turn) — and so does the second. Then `rho turns` reads the mainline: every turn in
  # position order, each reply naming the Run `say` printed, a position window under `--after`, and
  # the document whole under `--json`.
  def test_a_promptless_open_follows_a_turnless_row_and_each_say_prints_the_turn_it_opened_which_turns_lists
    project = connect!

    opened, status = @daemon.cli("do", "--model", MODEL, "--dir", project)
    assert_predicate status, :success?, "rho do (no prompt) failed:\n#{opened}"
    conversation = opened[/^conversation:\s+(\S+)/, 1]
    refute_nil conversation, "rho do printed no conversation:\n#{opened}"
    refute_match(/^(turn|run|pending):/, opened, "nothing a turn carries is printed: none was opened\n#{opened}")
    assert_match(/^next:\s+rho say #{Regexp.escape(conversation)}/, opened, opened)
    row = @daemon.control(:get, "/followers").fetch("followers").find { |candidate| candidate.fetch("public_id") == conversation }
    refute_nil row, "the daemon follows the conversation it opened"
    assert_equal "conversation", row.fetch("host_type")
    assert_nil row["run_public_id"], "no turn, no backing loop: #{row.inspect}"
    assert_empty feed(conversation).select { |item| item["type"] == "turn_status" }, "no turn on the feed"
    assert_empty inputs(conversation), "no prompt, no input"

    first_said, status = @daemon.cli("say", conversation, "!mock -- first words", "--mode", "queue")
    assert_predicate status, :success?, "rho say failed:\n#{first_said}"
    assert_match(/^queued:\s+\S+ \(pending\)$/, first_said, first_said)
    first_turn, first_loop = %w[turn run].map { |line| first_said[/^#{line}:\s+(\S+)/, 1] }
    refute_includes [first_turn, first_loop], nil, "rho say printed no turn or loop:\n#{first_said}"
    assert_equal "completed", await_run_status(first_loop, "completed").fetch("status")
    opened_turn = await_feed(conversation, "the first say's turn never ran on the feed") do |items|
      turn_status(items, status: "running", loop: first_loop)
    end
    assert_equal first_turn, opened_turn.dig("payload", "turn_public_id"), "the ids say printed are the feed's"
    assert_equal "completed", await_follower(conversation, loop: first_loop).fetch("status")

    second_said, status = @daemon.cli("say", conversation, "!mock -- second words", "--mode", "queue")
    assert_predicate status, :success?, "the second rho say failed:\n#{second_said}"
    second_turn, second_loop = %w[turn run].map { |line| second_said[/^#{line}:\s+(\S+)/, 1] }
    refute_includes [second_turn, second_loop], nil, second_said
    refute_equal first_loop, second_loop, "the second say answered the loop minted for ITS words, never the first's"
    assert_equal "completed", await_run_status(second_loop, "completed").fetch("status")
    await_follower(conversation, loop: second_loop)

    listed, status = @daemon.cli("turns", conversation)
    assert_predicate status, :success?, "rho turns failed:\n#{listed}"
    rows = listed.lines.map(&:chomp).grep(/\A\s+\d+  /)
    positions = rows.map { |line| line[/\A\s+(\d+)  /, 1].to_i }
    assert_equal positions.sort, positions, "position order:\n#{listed}"
    assert_equal positions.uniq, positions
    replies = rows.select { |line| line.include?("  assistant  ") }
    assert_equal [first_loop, second_loop], replies.map { |line| line[/  run (\S+)/, 1] },
      "each reply names the Run `say` printed:\n#{listed}"
    assert_includes listed, "second words", "the words ride the line"
    refute_match(/^more:/, listed, "four turns need no second window")

    windowed, status = @daemon.cli("turns", conversation, "--after", positions.first.to_s)
    assert_predicate status, :success?, windowed
    assert_equal positions.drop(1), windowed.lines.map(&:chomp).grep(/\A\s+\d+  /).map { |line| line[/\A\s+(\d+)  /, 1].to_i },
      "the window is exclusive of the position named:\n#{windowed}"

    json, status = @daemon.cli("turns", conversation, "--json")
    assert_predicate status, :success?, json
    document = JSON.parse(json[json.index("{")..])
    assert_equal positions, document.fetch("turns").map { |turn| turn.fetch("position") }
    assert_equal({ "after_position" => positions.last, "has_more" => false }, document.fetch("pagination"))
  end

  # `say --approval ask` PARKS THE NEXT TURN'S COMMAND (ACP design r2 C2;
  # the tightening on one later turn), and A ROW THE STORE FORGOT IS
  # ATTACHED BY ITS CONVERSATION ID (C4): the daemon restarted over an
  # emptied store follows nothing — `rho say` says so — and `rho attach ID
  # --conversation` follows the conversation's own feed again, after which
  # `say` opens a turn on it as before.
  def test_say_with_approval_ask_parks_the_command_and_a_forgotten_row_is_attached_by_its_conversation_id
    project = connect!
    conversation, _turn, first_loop = open_turn("!mock -- open", project)
    await_run_status(first_loop, "completed")
    await_follower(conversation, loop: first_loop)

    arguments = CGI.escape(JSON.generate({ "command" => "printf held > held.txt" }))
    said, status = @daemon.cli("say", conversation, "!mock tool_call=bash tool_args=#{arguments} -- run it",
      "--mode", "queue", "--approval", "ask")
    assert_predicate status, :success?, "rho say --approval ask failed:\n#{said}"
    loop = said[/^run:\s+(\S+)/, 1]
    refute_nil loop, said
    held = await_park(loop)
    assert_equal "bash", held.fetch("tool_name"), "the ask tightening parked the command: #{held.inspect}"
    refute File.exist?(File.join(project, "held.txt")), "nothing ran while the call was held"
    denied, status = @daemon.cli("deny", loop, held.fetch("key"), "not this time")
    assert_predicate status, :success?, "rho deny failed:\n#{denied}"
    await_run_status(loop, "completed")
    await_follower(conversation, loop: loop)

    # THE FORCED EVICTION: the store is a bounded cache under tmp/ (losing
    # it costs a follower, never the work); an emptied one over a restart
    # is the row a daemon forgot.
    cache = @daemon.host_cache_path
    @daemon.stop
    assert_path_exists cache
    File.unlink(cache)
    @daemon.start
    await_workspace_state("adopted")
    refute(@daemon.control(:get, "/followers").fetch("followers").any? { |row| row.fetch("public_id") == conversation },
      "the restarted daemon follows the forgotten row")
    refused, status = @daemon.cli("say", conversation, "!mock -- anyone?", "--mode", "queue")
    refute_predicate status, :success?, "rho say on a forgotten row must refuse:\n#{refused}"
    assert_match(/attach/, refused, "the refusal names the way back:\n#{refused}")

    attached, status = @daemon.cli("attach", conversation, "--conversation")
    assert_predicate status, :success?, "rho attach --conversation failed:\n#{attached}"
    assert_match(/^#{Regexp.escape(conversation)}  conversation  followed$/, attached, attached)
    row = @daemon.control(:get, "/followers").fetch("followers").find { |candidate| candidate.fetch("public_id") == conversation }
    refute_nil row, "the conversation is followed again"
    assert_equal "conversation", row.fetch("host_type")

    said, status = @daemon.cli("say", conversation, "!mock -- and again", "--mode", "queue", "--model", MODEL)
    assert_predicate status, :success?, "rho say after the attach failed:\n#{said}"
    again = said[/^run:\s+(\S+)/, 1]
    refute_nil again, said
    refute_includes [first_loop, loop], again
    assert_equal "completed", await_run_status(again, "completed").fetch("status")
    assert_equal "completed", await_follower(conversation, loop: again).fetch("status")
  end
end

require "support/rho_conversation_helpers"
