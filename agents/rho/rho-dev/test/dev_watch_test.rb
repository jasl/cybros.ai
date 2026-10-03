require "test_helper"

# THE WATCH COMPOSITION (`Rho::Dev::Watch.poll`, the body of `rho watch`):
# the once-per-change table over `core.loop_row`, the shared renderers
# under this gem's hints, and all four of the poll's exits — against
# scripted daemons whose rows are the script. `watch` is the verb every
# live journey leans on; its exits are pinned here and nowhere else.
class DevWatchTest < Minitest::Test
  include RhoTest::CliHarness

  def watch(public_id, **options) = Rho::Dev::Watch.poll(cli, public_id, interval: 0, **options)

  def watching_row(tasks, complete: false, status: "running", loop_status: status)
    { "loops" => [{ "public_id" => "al-7", "status" => status, "loop_status" => loop_status,
                    "complete" => complete, "tasks" => tasks }] }
  end

  # `rho watch LOOP_ID`, as the dispatcher invokes it: the options as Thor
  # parsed them reach the poll.
  def test_watch_is_the_verbs_body
    announce(endpoint: routed_endpoint("GET /loops" => [[200, watching_row([], complete: true, status: "completed")]]))

    assert_equal "completed", Rho::Dev::Watch.watch(cli, ["al-7"], { timeout: 5 })
    assert_match(/^status:    completed$/, @out.string)
  end

  # A SCHEDULED ROW on the watched host's snapshot prints its
  # own line with the time the kernel holds, whatever the origin.
  def test_watch_prints_a_scheduled_row_with_its_time_whatever_the_origin
    row = watching_row([{ "task_key" => "r1", "kind" => "model_task", "status" => "completed" }], complete: true, status: "completed")
    row.fetch("loops").first["mailed"] = [
      { "input_public_id" => "cin-4", "origin" => "person", "deliver_at" => "2026-09-16T09:20:00Z" },
      { "input_public_id" => "cin-5", "origin" => "agent", "sender_conversation_public_id" => "c-peer",
        "deliver_at" => "2026-09-16T10:00:00Z", "authored_by" => { "kind" => "agent", "handle" => "lark", "display_name" => "Lark" } },
    ]
    announce(endpoint: routed_endpoint("GET /loops" => [[200, row]]))

    assert_equal "completed", watch("al-7")
    assert_match(/^scheduled: cin-4 for 2026-09-16T09:20:00Z$/, @out.string, @out.string)
    assert_match(/^scheduled: cin-5 for 2026-09-16T10:00:00Z$/, @out.string)
    refute_match(/^\s+sent\s+cin-5$/, @out.string, "the scheduled line is the row's one line")
  end

  # A TURN-SHAPED `failed` IS A LEVEL: the loop is holding for
  # a person, so the watch ends with the verb that reopens it — where a
  # loop that failed for good is simply over.
  def test_watch_ends_on_a_hold_with_the_hint_that_reopens_it
    announce(endpoint: routed_endpoint("GET /loops" => [[200, watching_row(
      [{ "task_key" => "work", "kind" => "model_task", "status" => "failed", "error_key" => "provider_http_error" }],
      complete: true, status: "failed", loop_status: "needs_attention"
    )]]))

    assert_equal "failed", watch("al-7")
    assert_match(/^holding:\s+`rho retry al-7` or `rho answer al-7 …` reopens it$/, @out.string, @out.string)

    @out = StringIO.new
    announce(endpoint: routed_endpoint("GET /loops" => [[200, watching_row([], complete: true, status: "failed", loop_status: "canceled")]]))
    watch("al-7")
    refute_match(/holding:/, @out.string, "a loop that failed for good has nothing to reopen")
  end

  # WHAT THE RUNNER IS DOING RIGHT NOW: the frames the daemon
  # holds print once each by their sequence, indented under the key that
  # produced them, and a frame a poll missed is simply not printed.
  def test_watch_prints_the_progress_frames_indented_under_their_keys
    running = { "task_key" => "r1t0", "kind" => "tool_task", "status" => "dispatched" }
    frames = [
      { "seq" => 1, "type" => "executor_progress", "task_key" => "r1t0", "tool_name" => "bash", "payload" => { "text_tail" => "tick 1\ntick 2\n" } },
      { "seq" => 2, "type" => "process_output", "process_id" => "p3", "payload" => { "lines" => ["up", "ready"] } },
    ]
    later = frames + [
      { "seq" => 3, "type" => "executor_progress", "task_key" => "r1t0", "tool_name" => "bash", "payload" => { "text_tail" => "tick 2\ntick 3" } },
      { "seq" => 4, "type" => "executor_progress", "task_key" => "r1t0", "tool_name" => "bash", "payload" => { "text_tail" => "tick 3\n" } },
      { "seq" => 5, "type" => "process_output", "process_id" => "p3", "payload" => { "lines" => [], "exit" => 0 } },
      { "seq" => 6, "type" => "zz_future", "payload" => { "x" => 1 } },
    ]
    first = watching_row([running]).tap { |row| row["loops"].first["frames"] = frames }
    second = watching_row([running]).tap { |row| row["loops"].first["frames"] = later }
    announce(endpoint: routed_endpoint(
      "GET /loops" => [[200, first], [200, first], [200, second], [200, second],
                       [200, watching_row([running.merge("status" => "completed")], complete: true, status: "completed")]]
    ))

    assert_equal "completed", watch("al-7")
    lines = @out.string.lines.map(&:chomp)
    assert_equal ["  r1t0           │ tick 2", "  p3             │ up", "  p3             │ ready",
                  "  r1t0           │ tick 3", "  p3             │ exited 0"],
      lines.select { |line| line.include?(" │ ") }, @out.string
  end

  # THE KERNEL'S OWN FRAMES: a round dialled, a call dispatched, run
  # or held, a claim — each once, by its sequence, in the same column.
  def test_watch_prints_the_kernels_frames_under_the_round_or_call_they_name
    running = { "task_key" => "r2t0", "kind" => "tool_task", "status" => "dispatched" }
    frames = [
      { "seq" => 1, "type" => "round_started", "task_key" => "r1", "at" => "2026-09-14T10:00:00.250Z",
        "payload" => { "spine" => true, "attempt" => 1, "model" => "dev/mock-text", "request_bytes" => 41_208 } },
      { "seq" => 2, "type" => "step_started", "task_key" => "r2t0", "tool_name" => "read_file", "payload" => { "status" => "needs_approval" } },
      { "seq" => 3, "type" => "step_started", "task_key" => "r2t0", "tool_name" => "read_file", "payload" => { "status" => "dispatched" } },
      { "seq" => 4, "type" => "step_claimed", "task_key" => "r2t0", "tool_name" => "read_file", "executor_public_id" => "ex-1", "payload" => {} },
      { "seq" => 5, "type" => "round_started", "task_key" => "r2t1-model-1",
        "payload" => { "spine" => false, "attempt" => 2, "model" => "dev/mock-text", "request_bytes" => 512 } },
    ]
    first = watching_row([running]).tap { |row| row["loops"].first["frames"] = frames }
    announce(endpoint: routed_endpoint(
      "GET /loops" => [[200, first], [200, first], [200, watching_row([running.merge("status" => "completed")], complete: true, status: "completed")]]
    ))

    assert_equal "completed", watch("al-7")
    lines = @out.string.lines.map(&:chomp)
    assert_equal ["  r1             │ started · dev/mock-text · 40.2KB · attempt 1",
                  "  r2t0           │ read_file needs_approval",
                  "  r2t0           │ read_file dispatched",
                  "  r2t0           │ claimed by ex-1",
                  "  r2t1-model-1 (branch) │ started · dev/mock-text · 512B · attempt 2"],
      lines.select { |line| line.include?(" │ ") }, @out.string
  end

  # THE RUNNER ASKED FOR MORE TIME: the park's line reprints with the ask,
  # in minutes a person reads a park in, and only once per ask.
  def test_watch_prints_the_runners_ask_for_more_time_beside_the_park_it_extends
    parked = { "task_key" => "r1t0", "kind" => "tool_task", "status" => "dispatched" }
    # Each state twice: a watch iteration with a dispatched row reads
    # `/loops` and then the task (the runner-wait line), and the route
    # answers both from one sequence.
    states = [watching_row([parked]), watching_row([parked.merge("extension_ms" => 300_000)]),
              watching_row([parked.merge("extension_ms" => 45_000)])]
    announce(endpoint: routed_endpoint(
      "GET /loops" => states.flat_map { |row| [[200, row], [200, row]] } +
        [[200, watching_row([parked.merge("status" => "completed")], complete: true, status: "completed")]]
    ))

    assert_equal "completed", watch("al-7")
    out = @out.string
    assert_equal 1, out.scan(/^  dispatched     r1t0  — runner asked for 5 more minutes$/).length, out
    assert_match(/^  dispatched     r1t0  — runner asked for 45 more seconds$/, out, out)
    assert_match(/^  completed      r1t0$/, out, out)
  end

  # AN UNCERTAIN CALL PRINTS ITS OWN HINT, and the hold's own
  # hint fires beside it.
  def test_watch_prints_the_uncertain_hint_beside_the_call_and_the_hold_that_reopens_it
    announce(endpoint: routed_endpoint("GET /loops" => [[200, watching_row(
      [{ "task_key" => "r1", "kind" => "model_task", "status" => "completed" },
       { "task_key" => "r1t0", "kind" => "tool_task", "status" => "uncertain", "error_key" => "tool_uncertain" }],
      complete: true, status: "failed", loop_status: "needs_attention"
    )]]))

    assert_equal "failed", watch("al-7")
    out = @out.string
    assert_match(/^  uncertain      r1t0  \(tool_uncertain\)  — effect uncertain: check, then `rho retry` or `rho abandon`$/, out, out)
    assert_match(/^holding:/, out, "the loop holds for a person")
    refute_match(/^  completed      r1  —/, out, "the hint is the uncertain word's alone")
  end

  # A STEP A PROVIDER DECLINED: the line carries the category, WHO
  # declined, and — the step stood, nothing re-ran it — the verb that
  # re-runs it on another model; a null category drops the word, never
  # invents one; a content block names the verb that moves past it,
  # because blocked content is never re-sent; an absorbed member, which
  # the kernel will not retry, is offered nothing.
  def test_watch_prints_a_refused_steps_category_its_model_and_the_retry_on_another_model
    declined = { "kind" => "model_task", "status" => "failed", "error_key" => "model_refused",
                 "model" => "dev/primary", "finish_quality" => "refused" }
    announce(endpoint: routed_endpoint("GET /loops" => [[200, watching_row(
      [declined.merge("task_key" => "r2", "refusal_category" => "cyber"),
       declined.merge("task_key" => "r3"),
       declined.merge("task_key" => "r4", "finish_quality" => "blocked", "refusal_category" => "SPII",
         "model" => "dev/blocked"),
       declined.merge("task_key" => "normalize-b", "refusal_category" => "cyber", "on_failure" => "absorb")],
      complete: true, status: "failed", loop_status: "needs_attention"
    )]]))

    assert_equal "failed", watch("al-7")
    out = @out.string
    shown = out.lines.map(&:chomp)
    assert_includes shown, "  failed         r2  (model_refused: cyber — declined by dev/primary; " \
                           "`rho retry al-7 r2 --model provider/model` re-runs it on another model)", out
    assert_includes shown, "  failed         r3  (model_refused — declined by dev/primary; " \
                           "`rho retry al-7 r3 --model provider/model` re-runs it on another model)", out
    assert_includes shown, "  failed         r4  (model_refused: SPII — blocked by dev/blocked; " \
                           "`rho abandon al-7 r4`, then rephrase: blocked content is never re-sent)", out
    assert_includes shown, "  failed         normalize-b  (model_refused: cyber — declined by dev/primary)",
      "an absorbed member was its reader's to read: the kernel refuses a retry there, so none is offered:\n#{out}"
  end

  # A STEP THE KERNEL MOVED: the line that says it waits again names the
  # model it left, where it went and why — once, on the status that moved.
  def test_watch_prints_a_switch_once_on_the_status_that_moved
    switched = { "task_key" => "r2", "kind" => "model_task", "status" => "waiting",
                 "model_change" => { "from" => "dev/primary", "to" => "dev/fallback",
                                     "reason" => "model_refused", "category" => "cyber" } }
    announce(endpoint: routed_endpoint("GET /loops" => [
      [200, watching_row([{ "task_key" => "r2", "kind" => "model_task", "status" => "running" }])],
      [200, watching_row([switched])],
      [200, watching_row([switched.merge("status" => "completed").except("model_change")], complete: true, status: "completed")],
    ]))

    assert_equal "completed", watch("al-7")
    out = @out.string
    assert_includes out.lines.map(&:chomp),
      "  waiting        r2  — switched from dev/primary to dev/fallback (model_refused: cyber)", out
    assert_equal 1, out.scan("switched from").length, out
    assert_match(/^  completed      r2$/, out, out)
  end

  # A LOOP ID NAMES ITS HOST'S ROW: `rho watch LOOP_ID` finds the
  # conversation whose turn it backs or backed.
  def test_watch_finds_the_row_by_the_backing_loop
    announce(endpoint: routed_endpoint(
      "GET /loops" => [[200, { "loops" => [{ "public_id" => "c-1", "loop" => "al-8", "loops" => %w[al-7 al-8],
                                             "status" => "completed", "complete" => true, "tasks" => [] }] }]]
    ))

    assert_equal "completed", watch("al-7")
    assert_equal "completed", watch("al-8")
    assert_raises(Rho::Error) { watch("al-9") }
  end

  def test_watch_stops_when_the_loop_is_over
    announce(endpoint: routed_endpoint("GET /loops" => [[200, watching_row(
      [{ "task_key" => "work", "kind" => "model_task", "status" => "completed" }], complete: true, status: "completed"
    )]]))

    assert_equal "completed", watch("al-7")
    assert_match(/^\s+completed\s+work$/, @out.string, @out.string)
  end

  # A WATCH ENDS ON THE LEVEL, NEVER ON A TASK SHAPE: only `complete` is
  # the end of the turn, and the watcher waits for it.
  def test_watch_on_a_conversation_row_ends_on_complete_and_never_on_a_task_shape
    announce(endpoint: routed_endpoint("GET /loops" => [
      [200, watching_row([{ "task_key" => "r1", "kind" => "model_task", "status" => "completed" },
                          { "task_key" => "r1t0", "kind" => "await_task", "status" => "awaiting_input" }])],
      [200, watching_row([{ "task_key" => "r1", "kind" => "model_task", "status" => "completed" },
                          { "task_key" => "r1t0", "kind" => "await_task", "status" => "completed" },
                          { "task_key" => "r2", "kind" => "model_task", "status" => "completed" }], complete: true, status: "completed")],
    ]))

    assert_equal "completed", watch("al-7")
    assert_match(/^\s+awaiting_input\s+r1t0$/, @out.string, "the first poll was not the last")
    assert_match(/^\s+completed\s+r2$/, @out.string, @out.string)
    refute_match(/your turn|continue/, @out.string, "there is no second verb to hand the turn to")
  end

  # A BRANCH READS AS A BRANCH: the round prints
  # indented under the call key that minted it; a pre-dispatch round says
  # what it still waits on, and says it again only when that changes.
  def test_watch_indents_a_branch_under_its_call_key_and_says_what_a_waiting_round_waits_on
    announce(endpoint: routed_endpoint("GET /loops" => [
      [200, watching_row([
        { "task_key" => "r3", "kind" => "model_task", "status" => "completed" },
        { "task_key" => "r4t4", "kind" => "tool_task", "status" => "completed", "after" => %w[r3] },
        { "task_key" => "r4t4-model-1", "kind" => "model_task", "status" => "completed", "after" => %w[r4t4] },
        { "task_key" => "r5", "kind" => "model_task", "status" => "running", "after" => %w[r4t4-model-1] },
        { "task_key" => "r4", "kind" => "model_task", "status" => "waiting", "after" => %w[r4t4 r4t4-model-1 r5] },
      ])],
      [200, watching_row([
        { "task_key" => "r3", "kind" => "model_task", "status" => "completed" },
        { "task_key" => "r4t4", "kind" => "tool_task", "status" => "completed", "after" => %w[r3] },
        { "task_key" => "r4t4-model-1", "kind" => "model_task", "status" => "completed", "after" => %w[r4t4] },
        { "task_key" => "r5", "kind" => "model_task", "status" => "completed", "after" => %w[r4t4-model-1] },
        { "task_key" => "r6", "kind" => "model_task", "status" => "running", "after" => %w[r5] },
        { "task_key" => "r4", "kind" => "model_task", "status" => "waiting", "after" => %w[r4t4 r4t4-model-1 r5 r6] },
      ], complete: true)],
    ]))

    watch("al-7")
    out = @out.string

    assert_match(/^  completed      r3$/, out, out)
    assert_match(/^  completed      r4t4$/, out, "a spine call prints as before")
    assert_match(/^    completed      r4t4-model-1  \(r4t4\)$/, out, "the branch root, under its call")
    assert_match(/^    running        r5  \(r4t4\)$/, out, "a branch round, under the call it descends from")
    assert_match(/^    completed      r5  \(r4t4\)$/, out)
    assert_match(/^    running        r6  \(r4t4\)$/, out, "two hops up the chain is the same call")
    assert_match(/^  waiting        r4  waiting_on: r5$/, out, "the spine consumer, and what holds it")
    assert_match(/^  waiting        r4  waiting_on: r6$/, out, "printed again when what it waits on moved")
    assert_equal 2, out.scan(/^  waiting        r4\b/).length, "and only then"
    refute_match(/^\s+\S+\s+r4t4-model-1$/, out, "the root never prints as a spine line")
  end

  # A BACKGROUND TASK MAY OUTLIVE ITS TURN: read off the table,
  # never a flag — and the kernel's mail prints once, by the key the model saw.
  def test_watch_names_the_background_work_a_final_reply_left_running_and_the_mail_that_delivered_it
    announce(endpoint: routed_endpoint("GET /loops" => [[200, watching_row(
      [{ "task_key" => "r2", "kind" => "model_task", "status" => "completed" },
       { "task_key" => "r2t0", "kind" => "tool_task", "status" => "completed" },
       { "task_key" => "r2t0-model-1", "kind" => "model_task", "status" => "running" }],
      complete: true, status: "completed", loop_status: "running"
    )]]))

    assert_equal "completed", watch("al-7")
    assert_match(/^status:\s+completed$/, @out.string)
    assert_match(/^background: r2t0-model-1 running — its result reaches the next turn; rho watch al-7 follows$/, @out.string, @out.string)
    refute_match(/background: r2\b/, @out.string, "a settled task is not background")

    @out = StringIO.new
    announce(endpoint: routed_endpoint("GET /loops" => [[200, watching_row([{ "task_key" => "r2", "kind" => "model_task", "status" => "completed" }],
      complete: true, status: "completed", loop_status: "completed")
      .tap { |row| row["loops"].first["mailed"] = [{ "task_key" => "r2t0", "input_public_id" => "in-9" }] }]]))
    watch("al-7")
    refute_match(/background:/, @out.string, "a loop that completed left nothing running")
    assert_match(/^\s+mailed\s+r2t0$/, @out.string, @out.string)
    assert_equal 1, @out.string.scan(/mailed\s+r2t0/).length
  end

  # THE SPEAKER LINE, THE CHILD TREE, WHO RESOLVED a park.
  def test_watch_prints_the_speaker_under_mail_the_children_and_who_resolved_a_park
    row = watching_row([{ "task_key" => "r2", "kind" => "model_task", "status" => "completed" },
                        { "task_key" => "r1t0-ask-1", "kind" => "await_task", "status" => "completed",
                          "resolved_by" => { "kind" => "human", "public_id" => "0199-steward" } },
                        { "task_key" => "r1t1-ask-1", "kind" => "await_task", "status" => "completed",
                          "resolved_by" => { "kind" => "human", "public_id" => "0199-ada", "handle" => "ada" } },
                        { "task_key" => "r1t0-spawn-1", "kind" => "await_task", "status" => "completed",
                          "resolved_by" => { "kind" => "conversation", "public_id" => "c-child" } }],
      complete: true, status: "completed", loop_status: "completed")
    row["loops"].first["mailed"] = [
      { "task_key" => "r2t0", "input_public_id" => "in-9", "origin" => "child", "sender_conversation_public_id" => "c-child",
        "authored_by" => { "kind" => "agent", "handle" => "rho", "display_name" => "rho" } },
      { "input_public_id" => "in-12", "origin" => "agent", "sender_conversation_public_id" => "c-peer",
        "authored_by" => { "kind" => "agent", "handle" => "lark", "display_name" => "Lark" } },
      { "task_key" => "r2t1", "input_public_id" => "in-13" },
    ]
    row["loops"].first["children"] = [
      { "public_id" => "c-child", "label" => "reviewer", "spawn_node_key" => "r2t0", "answering_user_public_id" => "peer-1", "busy" => true },
      { "public_id" => "c-other", "answering_user_public_id" => "0199-user", "busy" => false },
    ]
    announce(endpoint: routed_endpoint("GET /loops" => [[200, row]]))

    watch("al-7")
    out = @out.string

    assert_match(/^  mailed         r2t0\n    from: @rho \(agent\) c-child$/, out, out)
    assert_match(/^  sent           in-12\n    from: @lark \(agent\) c-peer$/, out, out)
    assert_match(/^  mailed         r2t1$/, out, "no author, no from line")
    assert_match(/^  spawned        c-child \(reviewer, r2t0\) answered by peer-1 — replying$/, out, out)
    assert_match(/^  spawned        c-other answered by 0199-user — idle$/, out, out)
    assert_match(/^    completed      r1t0-ask-1  \(r1t0\)  resolved by human 0199-steward$/, out, out)
    assert_match(/^    completed      r1t1-ask-1  \(r1t1\)  resolved by human @ada$/, out)
    assert_match(/^    completed      r1t0-spawn-1  \(r1t0\)  resolved by conversation c-child$/, out)
    assert_equal 1, out.scan(/spawned        c-child/).length, "once while nothing moved"
  end

  def test_watch_reprints_a_child_when_a_reply_starts_or_ends_there
    busy = watching_row([], status: "running")
    busy["loops"].first["children"] = [{ "public_id" => "c-child", "answering_user_public_id" => "peer-1", "busy" => true }]
    idle = watching_row([], complete: true, status: "completed", loop_status: "completed")
    idle["loops"].first["children"] = [{ "public_id" => "c-child", "answering_user_public_id" => "peer-1", "busy" => false }]
    announce(endpoint: routed_endpoint("GET /loops" => [[200, busy], [200, busy], [200, idle]]))

    watch("al-7")
    out = @out.string

    assert_equal 2, out.scan(/spawned        c-child/).length, out
    assert_match(/replying\n(.*\n)*.*idle$/, out)
  end

  TODO_THREE = [
    { "content" => "Add the CLI entry", "status" => "completed" },
    { "content" => "Parse the input file", "status" => "in_progress" },
    { "content" => "Write the tests", "status" => "pending" },
  ].freeze
  TODO_BLOCK = ["  todo       - [x] Add the CLI entry",
                "             - [>] Parse the input file",
                "             - [ ] Write the tests"].freeze

  def todo_detail(todos, key: "r1t0", is_error: nil)
    { "key" => key, "kind" => "tool_task", "status" => "completed", "tool_name" => "todo_write",
      "tool_input" => { "todos" => todos }, "output" => "Todo list updated.",
      "result" => ({ "resolved" => true, "is_error" => is_error }.compact) }
  end

  def todo_frame(key, seq: 1, tool: "todo_write")
    { "seq" => seq, "type" => "step_started", "task_key" => key, "tool_name" => tool, "payload" => { "status" => "dispatched" } }
  end

  # THE PERSON'S CHECKLIST: when a `todo_write` call
  # reaches `completed`, the watch reads that ONE task (`core.task`) and
  # prints the list as a block, once per change, never per poll.
  def test_watch_prints_the_todo_block_once_per_change_and_reads_the_task_once
    dispatched = { "task_key" => "r1t0", "kind" => "tool_task", "status" => "dispatched" }
    done = dispatched.merge("status" => "completed")
    running = watching_row([dispatched]).tap { |row| row["loops"].first["frames"] = [todo_frame("r1t0")] }
    finished = watching_row([done]).tap { |row| row["loops"].first["frames"] = [todo_frame("r1t0")] }
    over = watching_row([done], complete: true, status: "completed").tap { |row| row["loops"].first["frames"] = [todo_frame("r1t0")] }
    seen = []
    # The harness matches routes by prefix in key order: the task read first.
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /loops/task?public_id=al-7&task_key=r1t0" => [[200, { "task" => todo_detail(TODO_THREE) }]],
      "GET /loops" => [[200, running], [200, finished], [200, finished], [200, over]]))

    assert_equal "completed", watch("al-7")

    lines = @out.string.lines.map(&:chomp)
    assert_equal ["  dispatched     r1t0", "  r1t0           │ todo_write dispatched", "  completed      r1t0", *TODO_BLOCK,
                  "status:    completed"], lines, "the block sits under the task line that announced it"
    reads = seen.count { |request| request.start_with?("GET /loops/task?public_id=al-7&task_key=r1t0") }
    assert_equal 2, reads, "the runner-wait probe on the dispatched poll, then ONE read for the change — never one per poll"
  end

  # An empty or all-completed list prints `(cleared)`; a call the frames
  # named as another tool costs no read; a refused write prints nothing;
  # a control character is escaped, a long line bounded at the ask width.
  def test_watch_prints_cleared_skips_other_tools_and_refused_writes_and_bounds_every_line
    tasks = %w[r1t0 r2t0 r3t0 r4t0].map { |key| { "task_key" => key, "kind" => "tool_task", "status" => "completed" } }
    frames = [todo_frame("r1t0", seq: 1, tool: "bash"), todo_frame("r2t0", seq: 2), todo_frame("r3t0", seq: 3), todo_frame("r4t0", seq: 4)]
    row = watching_row(tasks, complete: true, status: "completed").tap { |r| r["loops"].first["frames"] = frames }
    long = "x" * 100
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /loops/task?public_id=al-7&task_key=r4t0" => [[200, { "task" => todo_detail(
        [{ "content" => "tab\there", "status" => "pending" }, { "content" => long, "status" => "completed" }], key: "r4t0", is_error: true
      ) }]],
      "GET /loops/task?public_id=al-7&task_key=r3t0" => [[200, { "task" => todo_detail(
        [{ "content" => "tab\there", "status" => "in_progress" }, { "content" => long, "status" => "pending" }], key: "r3t0"
      ) }]],
      "GET /loops/task?public_id=al-7&task_key=r2t0" => [[200, { "task" => todo_detail([], key: "r2t0") }]],
      "GET /loops" => [[200, row]]))

    watch("al-7")

    lines = @out.string.lines.map(&:chomp)
    assert_equal ["  todo       - [>] tab\\u0009here", "             - [ ] #{"x" * 74}…"],
      lines.select { |line| line.start_with?("  todo ", "             ") }
    refute_match(/cleared/, @out.string, "the newest list of a frame wins; the older cleared one is stale")
    assert_empty seen.select { |request| request.include?("task_key=r1t0") }, "a call the frames named as bash costs no read"
    assert_empty seen.select { |request| request.include?("task_key=r2t0") }, "nothing older than the newest list is read"

    @out = StringIO.new
    cleared = watching_row([tasks[1]], complete: true, status: "completed").tap { |r| r["loops"].first["frames"] = [frames[1]] }
    announce(endpoint: routed_endpoint(
      "GET /loops/task?public_id=al-7&task_key=r2t0" => [[200, { "task" => todo_detail([], key: "r2t0") }]],
      "GET /loops" => [[200, cleared]]
    ))
    watch("al-7")
    assert_includes @out.string.lines.map(&:chomp), "  todo       (cleared)"
  end

  # NO FRAME NAMED THE CALL (a host re-adopted after a restart): the task
  # read itself names it, newest first, until the last `todo_write`.
  def test_watch_reads_an_unnamed_completed_call_to_learn_its_tool_newest_first
    tasks = [
      { "task_key" => "r1t0", "kind" => "tool_task", "status" => "completed" },
      { "task_key" => "r2", "kind" => "model_task", "status" => "completed" },
      { "task_key" => "r2t0", "kind" => "tool_task", "status" => "completed" },
    ]
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /loops/task?public_id=al-7&task_key=r2t0" => [[200, { "task" => todo_detail(TODO_THREE, key: "r2t0")
        .merge("tool_name" => "bash", "tool_input" => { "command" => "ls" }) }]],
      "GET /loops/task?public_id=al-7&task_key=r1t0" => [[200, { "task" => todo_detail(TODO_THREE) }]],
      "GET /loops" => [[200, watching_row(tasks, complete: true, status: "completed")]]))

    watch("al-7")

    assert_equal TODO_BLOCK, @out.string.lines.map(&:chomp).select { |line| line.include?("- [") }
    reads = seen.select { |request| request.start_with?("GET /loops/task") }.map { |request| request[/task_key=(\S+) /, 1] }
    assert_equal %w[r2t0 r1t0], reads, "newest first; a model task is never read"
  end

  # Fifty items print, then one line counts the rest — a display bound.
  def test_watch_bounds_the_todo_block_at_fifty_lines
    todos = (1..62).map { |n| { "content" => "step #{n}", "status" => "pending" } }
    row = watching_row([{ "task_key" => "r1t0", "kind" => "tool_task", "status" => "completed" }], complete: true, status: "completed")
      .tap { |r| r["loops"].first["frames"] = [todo_frame("r1t0")] }
    announce(endpoint: routed_endpoint(
      "GET /loops/task?public_id=al-7&task_key=r1t0" => [[200, { "task" => todo_detail(todos) }]],
      "GET /loops" => [[200, row]]
    ))

    watch("al-7")

    lines = @out.string.lines.map(&:chomp)
    assert_equal 50, lines.count { |line| line.include?("- [ ] step") }
    assert_includes lines, "  todo       - [ ] step 1"
    assert_includes lines, "             … and 12 more"
    refute_includes @out.string, "step 51"
  end

  def test_watch_gives_up_at_its_deadline_rather_than_polling_forever
    announce(endpoint: routed_endpoint("GET /loops" => [[200, watching_row([{ "task_key" => "work", "kind" => "model_task", "status" => "running" }])]]))

    ticks = [0, 99]
    error = assert_raises(Rho::Error) { watch("al-7", deadline: 5, clock: -> { ticks.shift || 99 }) }
    assert_match(/timed out watching al-7/, error.message)
  end

  # `rho watch` prints an inbox ask ONCE while it stands, beside the
  # follower's ASKING line, with the verb that answers it.
  def test_watch_prints_an_inbox_ask_once_with_the_answer_hint
    row = { "public_id" => "al-9", "status" => "running", "complete" => false, "tasks" => [],
            "attention" => { "reason" => "awaiting_human", "blocked_task_keys" => ["r1t0"] } }
    done = row.merge("status" => "completed", "complete" => true, "attention" => nil)
    announce(endpoint: routed_endpoint(
      "GET /loops" => [[200, { "loops" => [row] }], [200, { "loops" => [row] }], [200, { "loops" => [done] }]],
      "GET /asks" => [[200, { "asks" => [{ "kind" => "ask", "agent_loop_public_id" => "al-9", "task_key" => "r1t0", "prompt" => "which database?" }] }]]
    ))

    watch("al-9")

    lines = @out.string.lines
    assert_equal 1, lines.count { |line| line.start_with?("  ASKING     awaiting_human — r1t0") }
    assert_equal 1, lines.count { |line| line == "  ask        al-9 r1t0  \"which database?\"\n" }, "the inbox line prints once while the ask stands"
    assert_equal 1, lines.count { |line| line == "answer:    rho answer al-9 r1t0 \"…\"\n" }
  end

  # `rho watch` prints a held call ONCE while it stands — the park line for
  # each key, the ASKING line once per reason.
  def test_watch_prints_a_held_call_once_beside_the_asking_line
    row = { "public_id" => "al-9", "status" => "running", "complete" => false, "tasks" => [],
            "attention" => { "reason" => "approval_required", "blocked_task_keys" => ["r1t0"] } }
    two = row.merge("attention" => { "reason" => "approval_required", "blocked_task_keys" => %w[r1t0 r1t1] })
    done = row.merge("status" => "completed", "complete" => true, "attention" => nil)
    held = { "kind" => "approval", "agent_loop_public_id" => "al-9", "task_key" => "r1t0", "tool_name" => "bash",
             "tool_input" => { "command" => "git push --force origin main" } }
    second = held.merge("task_key" => "r1t1", "tool_input" => { "command" => "rm -rf build" })
    announce(endpoint: routed_endpoint(
      "GET /loops" => [[200, { "loops" => [row] }], [200, { "loops" => [two] }], [200, { "loops" => [two] }], [200, { "loops" => [done] }]],
      "GET /asks" => [[200, { "asks" => [held] }], [200, { "asks" => [held, second] }], [200, { "asks" => [held, second] }], [200, { "asks" => [] }]]
    ))

    watch("al-9")

    lines = @out.string.lines
    assert_equal 1, lines.count { |line| line.start_with?("  ASKING     approval_required — r1t0") }, "once per reason, not per key:\n#{@out.string}"
    assert_equal 1, lines.count { |line| line.start_with?("  ASKING") }
    assert_equal 1, lines.count { |line|
      line == "  approval   al-9 r1t0  bash \"git push --force origin main\"  → rho approve al-9 r1t0 | rho deny al-9 r1t0 [reason]\n"
    }, "the park line prints once while the call stands:\n#{@out.string}"
    assert_equal 1, lines.count { |line|
      line == "  approval   al-9 r1t1  bash \"rm -rf build\"  → rho approve al-9 r1t1 | rho deny al-9 r1t1 [reason]\n"
    }, "the second held call prints its own park line once"
    refute_match(/^answer:/, @out.string, "a held call has no answer hint; the verbs ride its line")
  end

  # `rho watch` says once, per change, that a dispatched call is waiting
  # for a runner that is not online — read off the task's addressee.
  def test_watch_says_once_per_change_when_a_dispatched_call_waits_for_a_runner_that_is_not_online
    seen = (Time.now - 200).utc.iso8601
    address = { "role" => "runner", "executor_public_id" => "0199-h", "presence" => "offline", "last_seen_at" => seen }
    task = { "key" => "r1t0", "kind" => "tool_task", "status" => "dispatched", "tool_name" => "read" }
    dispatched = watching_row([{ "task_key" => "r1", "kind" => "model_task", "status" => "running" },
                               { "task_key" => "r1t0", "kind" => "tool_task", "status" => "dispatched" }])
    # The harness matches routes by prefix in key order: the task read first
    # (this case sat behind a `private` in the old file and never ran).
    announce(endpoint: routed_endpoint(
      "GET /loops/task?public_id=al-7&task_key=r1t0" => [
        [200, { "task" => task.merge("addressed_to" => address) }],
        [200, { "task" => task.merge("addressed_to" => address) }],
        [200, { "task" => task.merge("addressed_to" => address.merge("presence" => "online")) }],
      ],
      "GET /loops" => [[200, dispatched], [200, dispatched], [200, dispatched],
                       [200, watching_row([{ "task_key" => "r1", "kind" => "model_task", "status" => "completed" },
                                           { "task_key" => "r1t0", "kind" => "tool_task", "status" => "completed" }],
                         complete: true, status: "completed")]]
    ))

    assert_equal "completed", watch("al-7")

    lines = @out.string.lines.map(&:chomp)
    assert_equal 1, lines.count("  waiting for runner 0199-h (offline, last seen 3m ago)"), lines.inspect
    assert_equal ["  running        r1", "  dispatched     r1t0", "  waiting for runner 0199-h (offline, last seen 3m ago)",
                  "  completed      r1", "  completed      r1t0", "status:    completed"], lines
  end

  def test_watch_reads_no_addressee_for_a_row_that_is_not_dispatched_and_tolerates_a_daemon_without_the_route
    announce(endpoint: routed_endpoint("GET /loops" => [[200, watching_row([{ "task_key" => "r1", "kind" => "model_task", "status" => "completed" }],
      complete: true, status: "completed")]]))
    assert_equal "completed", watch("al-7")
    refute_match(/waiting for runner/, @out.string)

    @out = StringIO.new
    announce(endpoint: routed_endpoint("GET /loops" => [
      [200, watching_row([{ "task_key" => "r1t0", "kind" => "tool_task", "status" => "dispatched" }])],
      [200, watching_row([{ "task_key" => "r1t0", "kind" => "tool_task", "status" => "completed" }], complete: true, status: "completed")],
    ]))
    assert_equal "completed", watch("al-7")
    refute_match(/waiting for runner/, @out.string, "a daemon without the task read prints no line")
  end
end
