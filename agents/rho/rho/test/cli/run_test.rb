require "test_helper"
require "pty"

# `rho run` AS A LIBRARY (`Rho::Cli::Run`): the composition
# — open, follow, deny what nobody can approve, read the answer, stop
# what it cannot finish — driven against scripted daemons whose streams
# are the script: each output format's exact bytes, each exit of the
# table (0 completed; 1 failed on a terminal loop, canceled, a refusal;
# 2 a hold, the model's ask, a keyless park, the deadline; 130 a signal),
# the deny branch's bodies, the socket-level timeout's wall time. The
# stdin shapes and Thor's refusal of `--approval` go through the shipped
# binary, because they are the dispatcher's.
class CliRunTest < Minitest::Test
  include RhoTest::CliHarness

  EXE = File.expand_path("../../exe/rho", __dir__)
  ROOT = File.expand_path("../..", __dir__)

  IDS = { "conversation" => { "public_id" => "c-9" }, "turn" => { "public_id" => "t-9" },
          "loop" => { "public_id" => "al-9" }, "compose" => { "on" => true, "source" => "row default" } }.freeze
  RESULT = { "result" => { "status" => "completed", "output" => "Hello, world" } }.freeze
  STOPPED = { "stopped" => { "public_id" => "c-9", "host_type" => "conversation", "status" => "canceled" } }.freeze
  DENIED = { "task" => { "key" => "r1c1", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "denied" } }.freeze
  DENY_REASON = "rho run: non-interactive; nobody can approve".freeze

  # One frame of the daemon's stream, as `LoopStream` writes it.
  def frame(type, payload) = "event: #{type}\ndata: #{JSON.generate(payload)}\n\n"

  SNAPSHOT = { "public_id" => "c-9", "host_type" => "conversation", "status" => "running", "loop" => "al-9",
               "turn" => "t-9", "complete" => false, "text" => "Hel",
               "tasks" => [{ "task_key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "running" }] }.freeze

  def completed_stream
    frame("snapshot", SNAPSHOT) +
      frame("text_delta", "text" => "lo") +
      frame("task_status", "task_key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed") +
      frame("turn_status", "status" => "completed", "loop_status" => "completed", "turn_public_id" => "t-9",
        "agent_loop_public_id" => "al-9") +
      frame("closed", "reason" => "turn_settled")
  end

  def setup
    super
    @err = StringIO.new
  end

  # The options as Thor hands them to the verb: symbol keys, the format's
  # default filled in. (`run` itself is Minitest's runner; the helper is
  # named for what it does to the verb.)
  def perform(prompt = "say hello", seen: nil, routes: {}, **options, &fold)
    options = { "output-format": "text" }.merge(options)
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /conversations" => [[201, IDS]],
      "GET /loops/follow?public_id=c-9" => [[200, completed_stream]],
      "GET /loops/result?public_id=al-9" => [[200, RESULT]],
      "POST /stop" => [[200, STOPPED]],
      "POST /loops/deny" => [[200, DENIED]],
    }.merge(routes)))
    Rho::Cli::Run.call(cli, prompt, options, err: @err, &fold)
  end

  def result_object = JSON.parse(@out.string.lines.last)

  # ---- the three formats ----

  # TEXT: the header `do` prints, the table and the reply as they stream,
  # `status:` and the answer, exit 0 — the bytes a person reads.
  def test_text_prints_the_header_the_stream_the_status_and_the_answer
    seen = []
    outcome = perform(seen: seen, model: "m/x", dir: "/srv/app")

    assert_equal 0, outcome.exit_status
    assert_equal "success", outcome.subtype
    refute outcome.is_error
    assert_equal "conversation: c-9\nturn:         t-9\nloop:         al-9\ncompose:      on (row default)\n" \
                 "  running        r1\n  │ Hello\n  completed      r1\nstatus:    completed\n\nHello, world\n",
      @out.string
    assert_equal "", @err.string, "nothing on stderr for a run that completed"
    body = JSON.parse(seen.grep(%r{\APOST /conversations }).first.partition("\r\n\r\n").last)
    # `--dir` BINDS: beside the
    # descriptive working directory, the environment the daemon records.
    assert_equal({ "prompt" => "say hello", "working_directory" => "/srv/app", "model" => "m/x",
                   "environment" => { "root" => "/srv/app", "directories" => [] } }, body)
    refute body.key?("approval_mode"), "run tightens nothing: the turn runs under rho's own rules"
    assert_empty seen.grep(%r{\APOST /stop }), "a completed run stops nothing"
  end

  # The fold an extension registered on `run` (rho.until's) reaches the body.
  def test_the_fold_block_shapes_the_body
    seen = []
    perform(seen: seen) { |body| body.merge("until" => { "command" => "true", "attempts" => 1 }) }

    body = JSON.parse(seen.grep(%r{\APOST /conversations }).first.partition("\r\n\r\n").last)
    assert_equal({ "command" => "true", "attempts" => 1 }, body.fetch("until"))
  end

  # `-p`: the answer alone, newline-terminated; nothing else on stdout.
  def test_print_prints_the_answer_alone
    outcome = perform(print: true)

    assert_equal 0, outcome.exit_status
    assert_equal "Hello, world\n", @out.string
  end

  # JSON: one object, its keys pinned as a sorted list, nothing before it.
  def test_json_prints_one_result_object
    outcome = perform("output-format": "json")

    assert_equal 0, outcome.exit_status
    assert_equal 1, @out.string.lines.length, @out.string
    object = result_object
    assert_equal %w[conversation_id denied_calls duration_ms is_error loop_id model_switches reason refusals result status
                    subtype turn_id type],
      object.keys.sort
    assert_equal "result", object.fetch("type")
    assert_equal "success", object.fetch("subtype")
    assert_equal false, object.fetch("is_error")
    assert_equal "completed", object.fetch("status")
    assert_nil object.fetch("reason")
    assert_operator object.fetch("duration_ms"), :>, 0
    assert_equal 0, object.fetch("denied_calls")
    assert_equal %w[c-9 t-9 al-9], object.values_at("conversation_id", "turn_id", "loop_id")
    assert_equal "Hello, world", object.fetch("result")
    assert_equal "", @err.string
  end

  # A PROVIDER DECLINED STEPS ON THE WAY: one served by the answerer's
  # fallback (`task_status.model_change`), one — a compose member its merge
  # absorbed — that stood (its `round_result`). The object carries both —
  # `model_switches` from the kernel's switch narration, `refusals` from
  # every declined round, the category absent when the provider named none
  # — the lines print them in the table, and `-p` says each switch once on
  # stderr, because a fallback's answer is not the asked model's.
  def refused_stream
    primary = "dev/primary"
    frame("snapshot", SNAPSHOT) +
      frame("task_status", "task_key" => "r2", "kind" => "model_task", "status" => "running", "agent_loop_public_id" => "al-9") +
      frame("task_status", "task_key" => "r2", "kind" => "model_task", "status" => "waiting", "agent_loop_public_id" => "al-9",
        "model_change" => { "from" => primary, "to" => "dev/fallback", "reason" => "model_refused", "category" => "cyber" }) +
      frame("round_result", "task_key" => "r2", "status" => "waiting", "model" => primary, "finish_quality" => "refused",
        "refusal_category" => "cyber", "error_detail" => "This request triggered restrictions.", "agent_loop_public_id" => "al-9") +
      frame("round_result", "task_key" => "r2", "status" => "completed", "model" => "dev/fallback", "agent_loop_public_id" => "al-9") +
      frame("task_status", "task_key" => "r3", "kind" => "model_task", "status" => "failed", "error_key" => "model_refused",
        "on_failure" => "absorb", "agent_loop_public_id" => "al-9") +
      frame("round_result", "task_key" => "r3", "status" => "failed", "model" => primary, "finish_quality" => "refused",
        "agent_loop_public_id" => "al-9") +
      frame("turn_status", "status" => "completed", "loop_status" => "completed", "turn_public_id" => "t-9",
        "agent_loop_public_id" => "al-9") +
      frame("closed", "reason" => "turn_settled")
  end

  def test_declined_steps_ride_the_object_the_table_and_the_print_line
    outcome = perform("output-format": "json", routes: { "GET /loops/follow?public_id=c-9" => [[200, refused_stream]] })

    assert_equal 0, outcome.exit_status
    switch = { "task" => "r2", "from" => "dev/primary", "to" => "dev/fallback",
               "reason" => "model_refused", "category" => "cyber" }
    assert_equal [switch], result_object.fetch("model_switches")
    assert_equal [{ "task" => "r2", "model" => "dev/primary", "category" => "cyber" },
                  { "task" => "r3", "model" => "dev/primary" }], result_object.fetch("refusals")
    assert_equal "", @err.string, "a structured mode carries it in the object alone"

    @out = StringIO.new
    perform(routes: { "GET /loops/follow?public_id=c-9" => [[200, refused_stream]] })
    shown = @out.string.lines.map(&:chomp)
    assert_includes shown, "  waiting        r2  — switched from dev/primary to dev/fallback " \
                           "(model_refused: cyber)", @out.string
    assert_includes shown, "  failed         r3  (model_refused — declined by dev/primary)",
      "an absorbed member's refusal was its reader's to read; nothing is offered to re-run:\n#{@out.string}"
    assert_equal "", @err.string, "the table said it"

    @out = StringIO.new
    perform(print: true, routes: { "GET /loops/follow?public_id=c-9" => [[200, refused_stream]] })
    assert_equal "Hello, world\n", @out.string, "the answer alone on stdout"
    assert_equal "rho run: r2 switched from dev/primary to dev/fallback (model_refused: cyber)\n",
      @err.string
  end

  # STREAM-JSON: every frame as it lands, `type` first in the daemon's own
  # vocabulary, the result object last; every line parses.
  def test_stream_json_prints_every_frame_then_the_result
    outcome = perform("output-format": "stream-json")

    assert_equal 0, outcome.exit_status
    lines = @out.string.lines.map { |line| JSON.parse(line) }
    assert_equal %w[snapshot text_delta task_status turn_status closed result], lines.map { |line| line.fetch("type") }
    assert_equal SNAPSHOT.merge("type" => "snapshot"), lines.first
    assert_equal({ "type" => "text_delta", "text" => "lo" }, lines[1])
    assert_equal "Hello, world", lines.last.fetch("result")
  end

  # ---- the exit table ----

  # A turn that FAILED on a terminal loop is over: 1, the failure reason,
  # `status:    failed`, and the honest "no deliverable" line.
  def test_a_failed_turn_on_a_terminal_loop_exits_1
    stream = frame("snapshot", SNAPSHOT) +
             frame("turn_status", "status" => "failed", "loop_status" => "canceled", "failure_reason" => "provider_http_error") +
             frame("closed", "reason" => "turn_settled")
    seen = []
    outcome = perform(seen: seen, routes: {
      "GET /loops/follow?public_id=c-9" => [[200, stream]],
      "GET /loops/result?public_id=al-9" => [[200, { "result" => { "status" => "failed", "output" => nil } }]],
    })

    assert_equal 1, outcome.exit_status
    assert_equal "failed", outcome.subtype
    assert_equal "provider_http_error", outcome.reason
    assert outcome.is_error
    assert_match(/^status:    failed\n\n\(none — this loop resolved no deliverable\)\n\z/, @out.string)
    assert_empty seen.grep(%r{\APOST /stop }), "a loop that ended for good has nothing to stop"
  end

  # Canceled by someone else: 1, `canceled`.
  def test_a_canceled_turn_exits_1
    stream = frame("snapshot", SNAPSHOT) +
             frame("turn_status", "status" => "canceled", "loop_status" => "canceled") +
             frame("closed", "reason" => "turn_settled")
    outcome = perform("output-format": "json", routes: {
      "GET /loops/follow?public_id=c-9" => [[200, stream]],
      "GET /loops/result?public_id=al-9" => [[200, { "result" => { "status" => "canceled", "output" => nil } }]],
    })

    assert_equal 1, outcome.exit_status
    assert_equal %w[canceled canceled], [outcome.subtype, result_object.fetch("status")]
    assert_nil result_object.fetch("result")
  end

  # A TURN-SHAPED `failed` ON A LIVE LOOP IS A HOLD: only a
  # retry or an answer reopens it and nobody here can — the run stops the
  # loop it opened and exits 2; the stream never closes on a hold, so the
  # verdict is the frame's, not the socket's.
  def test_a_hold_stops_the_loop_and_exits_2
    stream = frame("snapshot", SNAPSHOT) +
             frame("turn_status", "status" => "failed", "loop_status" => "needs_attention", "failure_reason" => "provider_http_error")
    seen = []
    outcome = perform(seen: seen, routes: { "GET /loops/follow?public_id=c-9" => [[200, stream]] })

    assert_equal 2, outcome.exit_status
    assert_equal "needs_person", outcome.subtype
    assert_equal "provider_http_error", outcome.reason
    stop = seen.grep(%r{\APOST /stop }).first
    refute_nil stop, "the run stops the loop it cannot finish"
    assert_equal({ "public_id" => "c-9", "force" => true, "host_type" => "conversation" },
      JSON.parse(stop.partition("\r\n\r\n").last))
    assert_equal "rho run: needs a person (the turn failed and the loop is holding — provider_http_error); " \
                 "the run stopped it\n", @err.string
    assert_match(/^status:    canceled$/, @out.string, "the status at the moment the run stopped it")
  end

  # THE MODEL'S ASK (`awaiting_human`): nothing to deny — stop, 2, the
  # sentence names the key; the structured object carries it and prints
  # no human line.
  def test_the_models_ask_stops_the_loop_and_exits_2
    stream = frame("snapshot", SNAPSHOT) +
             frame("attention_required", "reason" => "awaiting_human", "blocked_task_keys" => ["r2c1"])
    seen = []
    outcome = perform(seen: seen, routes: { "GET /loops/follow?public_id=c-9" => [[200, stream]] })

    assert_equal 2, outcome.exit_status
    assert_equal %w[needs_person awaiting_human], [outcome.subtype, outcome.reason]
    assert_equal "rho run: needs a person (awaiting_human — r2c1); the run stopped it\n", @err.string
    assert_match(/^  ASKING     awaiting_human — r2c1$/, @out.string)
    refute_empty seen.grep(%r{\APOST /stop })
    assert_empty seen.grep(%r{\APOST /loops/deny }), "an ask is not a park: nothing is denied"

    reset_out
    outcome = perform("output-format": "json", seen: seen, routes: { "GET /loops/follow?public_id=c-9" => [[200, stream]] })
    assert_equal 2, outcome.exit_status
    assert_equal "", @err.string, "a structured mode carries the error inside the object only"
    assert_equal %w[needs_person awaiting_human canceled], result_object.values_at("subtype", "reason", "status")
    assert_equal true, result_object.fetch("is_error")
  end

  # THE PARK (`approval_required` with keys): reasonix's letter — the call
  # fails closed and the run goes on. One `POST /loops/deny` per key with
  # the run's reason, a REFUSED line each, the exit is the turn's,
  # `denied_calls` counts them.
  def test_a_park_is_denied_and_the_run_continues
    stream = frame("snapshot", SNAPSHOT) +
             frame("attention_required", "reason" => "approval_required", "blocked_task_keys" => %w[r1c1 r1c2]) +
             frame("turn_status", "status" => "completed", "loop_status" => "completed") +
             frame("closed", "reason" => "turn_settled")
    seen = []
    outcome = perform(seen: seen, routes: { "GET /loops/follow?public_id=c-9" => [[200, stream]] })

    assert_equal 0, outcome.exit_status
    assert_equal 2, outcome.denied_calls
    denies = seen.grep(%r{\APOST /loops/deny }).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal [{ "public_id" => "al-9", "task_key" => "r1c1", "reason" => DENY_REASON },
                  { "public_id" => "al-9", "task_key" => "r1c2", "reason" => DENY_REASON }], denies
    assert_match(/^  ASKING     approval_required — r1c1, r1c2\n  REFUSED r1c1 — non-interactive run\n  REFUSED r1c2 — non-interactive run\n/,
      @out.string)
    assert_empty seen.grep(%r{\APOST /stop })
    assert_equal "", @err.string
  end

  # A park with NO key to deny: nobody can decide it — stop, 2.
  def test_a_keyless_park_stops_the_loop_and_exits_2
    stream = frame("snapshot", SNAPSHOT) +
             frame("attention_required", "reason" => "approval_required", "blocked_task_keys" => [])
    seen = []
    outcome = perform(seen: seen, routes: { "GET /loops/follow?public_id=c-9" => [[200, stream]] })

    assert_equal 2, outcome.exit_status
    assert_equal %w[needs_person approval_required], [outcome.subtype, outcome.reason]
    refute_empty seen.grep(%r{\APOST /stop })
    assert_empty seen.grep(%r{\APOST /loops/deny })
  end

  # A deny the daemon refuses is a call nobody here can decide: 2, the
  # daemon's sentence.
  def test_a_refused_deny_is_a_park_nobody_can_decide
    stream = frame("snapshot", SNAPSHOT) +
             frame("attention_required", "reason" => "approval_required", "blocked_task_keys" => ["r1c1"])
    outcome = perform(routes: {
      "GET /loops/follow?public_id=c-9" => [[200, stream]],
      "POST /loops/deny" => [[409, { "error" => { "code" => "stale_claim", "message" => "r1c1 is already decided" } }]],
    })

    assert_equal 2, outcome.exit_status
    assert_equal 0, outcome.denied_calls
    assert_equal "rho run: needs a person (approval_required — r1c1 is already decided); the run stopped it\n", @err.string
  end

  # THE DEADLINE IS THE SOCKET'S: a daemon that sends
  # nothing cannot outlive `--timeout`; the run stops the loop and exits
  # 2 within the budget and a socket's slack, never the heartbeat's.
  def test_a_silent_daemon_under_timeout_exits_2_within_the_budget
    seen = []
    announce(endpoint: serve do |client, request|
      seen << request.lines.first.to_s
      case request.lines.first.to_s
      when %r{\AGET /healthz}
        answer(client, 200, "status" => "ok", "version" => Rho::VERSION, "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION)
      when %r{\APOST /conversations} then answer(client, 201, IDS)
      when %r{\APOST /stop} then answer(client, 200, STOPPED)
      when %r{\AGET /loops/result} then answer(client, 200, "result" => { "status" => "canceled", "output" => nil })
      else
        client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
        client.write(frame("snapshot", SNAPSHOT))
        # Silent until the reader hangs up (the harness serves one
        # connection at a time, and the stop that follows must get through).
        IO.select([client], nil, nil, 4)
      end
    end)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outcome = Rho::Cli::Run.call(cli, "wait", { "output-format": "text", timeout: 1 }, err: @err)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 2, outcome.exit_status
    assert_equal %w[timeout timeout], [outcome.subtype, outcome.reason]
    assert_operator elapsed, :<, 3, "a 1 s deadline returns in well under the heartbeat (took #{elapsed.round(2)} s)"
    assert_equal "rho run: timed out after 1 s; the run stopped it\n", @err.string
    refute_empty seen.grep(%r{\APOST /stop }), "the run stops what it timed out on"
  end

  # A SIGNAL: Ruby raises it out of the read; the run stops the loop and
  # exits 130, never a backtrace.
  def test_a_signal_stops_the_loop_and_exits_130
    seen = []
    announce(endpoint: serve do |client, request|
      seen << request.lines.first.to_s
      case request.lines.first.to_s
      when %r{\AGET /healthz}
        answer(client, 200, "status" => "ok", "version" => Rho::VERSION, "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION)
      when %r{\APOST /conversations} then answer(client, 201, IDS)
      when %r{\APOST /stop} then answer(client, 200, STOPPED)
      when %r{\AGET /loops/result} then answer(client, 200, "result" => { "status" => "canceled", "output" => nil })
      else
        client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
        client.write(frame("snapshot", SNAPSHOT))
        Process.kill("INT", Process.pid)
        IO.select([client], nil, nil, 2)
      end
    end)

    outcome = Rho::Cli::Run.call(cli, "wait", { "output-format": "text" }, err: @err)

    assert_equal 130, outcome.exit_status
    assert_equal %w[canceled interrupted], [outcome.subtype, outcome.reason]
    refute_empty seen.grep(%r{\APOST /stop })
    assert_equal "rho run: interrupted; the run stopped it\n", @err.string
  end

  # A DAEMON REFUSAL is one sentence and 1: on stderr in text, inside the
  # object in json — never both.
  def test_a_refusal_is_one_sentence_and_exit_1
    refusal = [[422, { "error" => { "code" => "malformed", "message" => "model is required, as provider/reference" } }]]
    outcome = perform(routes: { "POST /conversations" => refusal })

    assert_equal 1, outcome.exit_status
    assert_equal "rho run: model is required, as provider/reference\n", @err.string
    assert_equal "", @out.string

    reset_out
    outcome = perform("output-format": "json", routes: { "POST /conversations" => refusal })
    assert_equal 1, outcome.exit_status
    assert_equal "", @err.string
    assert_equal %w[failed model\ is\ required,\ as\ provider/reference], result_object.values_at("subtype", "reason")
    assert_nil result_object.fetch("conversation_id")

    reset_out
    outcome = perform(routes: { "GET /loops/follow?public_id=c-9" => [[404, { "error" => { "message" => "c-9 is not followed" } }]] })
    assert_equal 1, outcome.exit_status
    assert_equal "rho run: c-9 is not followed\n", @err.string, "a refusal mid-follow is the same sentence"
  end

  # A PENDING TURN (the kernel had not materialized it within the daemon's
  # bound): the bare `pending:` line — no verb hint, a product home has
  # none — and the loop id when its input materializes; the result is
  # read on that loop, even if another input materialized first.
  def test_a_pending_turn_prints_the_bare_line_and_follows_its_materialized_input
    pending = { "conversation" => { "public_id" => "c-9" }, "pending" => true,
                "input" => { "public_id" => "i-9", "position" => { "cursor" => nil, "sequence" => 0 } },
                "compose" => { "on" => true, "source" => "row default" } }
    stream = frame("snapshot", "public_id" => "c-9", "host_type" => "conversation", "tasks" => []) +
             frame("turn_status", "status" => "running", "turn_public_id" => "t-9", "agent_loop_public_id" => "al-9") +
             frame("turn_status", "status" => "completed", "loop_status" => "completed") +
             frame("closed", "reason" => "turn_settled")
    events = [
      ["input_materialized", { "input_public_id" => "i-other", "turn_public_id" => "t-other" }],
      ["turn_status", { "turn_public_id" => "t-other", "agent_loop_public_id" => "al-other" }],
      ["input_materialized", { "input_public_id" => "i-9", "turn_public_id" => "t-9" }],
      ["turn_status", { "turn_public_id" => "t-9", "agent_loop_public_id" => "al-9" }],
    ].each_with_index.map do |(type, payload), index|
      { "public_id" => "ev-#{index + 1}", "sequence" => index + 1, "cursor" => "c#{index + 1}", "type" => type,
        "resource" => { "type" => "Conversation", "public_id" => "c-9" }, "occurred_at" => "2026-09-20T00:00:00Z", "payload" => payload }
    end
    outcome = perform(routes: { "POST /conversations" => [[201, pending]], "GET /loops/follow?public_id=c-9" => [[200, stream]],
      "GET /loops/events?public_id=c-9" => [[200, { "events" => events, "pagination" => { "next_after" => nil, "watermark" => 4 } }]] })

    assert_equal 0, outcome.exit_status
    assert_equal "conversation: c-9\npending:      the turn has not started yet\ncompose:      on (row default)\n" \
                 "loop:         al-9\nstatus:    completed\n\nHello, world\n", @out.string
    assert_equal %w[t-9 al-9], [outcome.turn_id, outcome.loop_id]
  end

  # THE STREAM CAN END A FRAME EARLY: a `closed` (or a bare end) before the
  # turn's word settles on the daemon's row.
  def test_a_stream_that_ends_before_the_word_settles_on_the_row
    stream = frame("snapshot", SNAPSHOT) + frame("closed", "reason" => "turn_settled")
    row = { "loops" => [SNAPSHOT.merge("status" => "completed", "loop_status" => "completed", "complete" => true)] }
    outcome = perform(routes: { "GET /loops/follow?public_id=c-9" => [[200, stream]], "GET /loops" => [[200, row]] })

    assert_equal 0, outcome.exit_status
    assert_match(/^status:    completed$/, @out.string)
  end

  # ---- through the shipped binary: stdin, and the flags run refuses ----

  # PROMPT absent or `-` reads stdin whole (stripped); empty is refused
  # in one sentence; absent on a TTY is Thor's usage error.
  def test_stdin_is_the_prompt_when_no_word_is_given
    seen = []
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /conversations" => [[201, IDS]],
      "GET /loops/follow?public_id=c-9" => [[200, completed_stream]],
      "GET /loops/result?public_id=al-9" => [[200, RESULT]],
    }))

    out, status = run_binary("run", "-p", stdin: "  explain this code\n")
    assert_equal 0, status, out
    assert_equal "Hello, world\n", out
    body = JSON.parse(seen.grep(%r{\APOST /conversations }).last.partition("\r\n\r\n").last)
    assert_equal "explain this code", body.fetch("prompt")

    out, status = run_binary("run", "-", "-p", stdin: "from a dash")
    assert_equal 0, status, out
    body = JSON.parse(seen.grep(%r{\APOST /conversations }).last.partition("\r\n\r\n").last)
    assert_equal "from a dash", body.fetch("prompt")

    out, status = run_binary("run", stdin: "   \n")
    assert_equal 1, status
    assert_equal "rho run: the prompt is empty\n", out

    out, status = run_binary_on_a_tty("run")
    assert_equal 1, status
    assert_match(/"rho run" was called with no arguments/, out)
    assert_match(/Usage: "rho run \[PROMPT\]"/, out)
  end

  # `--approval`, `--stream`, `--compose`, `--restricted` are `do`'s
  # (rho-dev's): on `run` each is Thor's usage error — a switch it does
  # not know is a word, and `run` takes one — exit 1, nothing opened.
  def test_run_refuses_the_flags_it_does_not_carry
    seen = []
    announce(endpoint: recording_routed_endpoint(seen, "POST /conversations" => [[201, IDS]]))
    %w[--approval --stream --compose --restricted].each do |flag|
      out, status = run_binary("run", "hello", flag, "ask")
      assert_equal 1, status, "#{flag} on run must be refused:\n#{out}"
      assert_match(/was called with arguments \["hello", "#{flag}", "ask"\]/, out)
      assert_match(/Usage: "rho run \[PROMPT\]"/, out)
    end
    assert_empty seen.grep(%r{\APOST /conversations }), "a refused flag opens nothing"
  end

  private

    def reset_out
      @out = StringIO.new
      @err = StringIO.new
    end

    def binary_env = { "RHO_HOME" => @root, "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile") }

    # The binary with its stdin fed from a pipe (never a TTY), stderr merged.
    def run_binary(*argv, stdin: "")
      out = IO.popen(binary_env, [Gem.ruby, EXE, *argv, "--nexus-url", "https://nexus.example"], "r+", err: [:child, :out]) do |io|
        io.write(stdin)
        io.close_write
        io.read
      end
      [out.to_s.force_encoding(Encoding::UTF_8).scrub, $?.exitstatus]
    end

    # The binary on a pseudo-terminal, so `$stdin.tty?` answers true.
    def run_binary_on_a_tty(*argv)
      output = +""
      status = nil
      PTY.spawn(binary_env, Gem.ruby, EXE, *argv, "--nexus-url", "https://nexus.example") do |reader, writer, pid|
        writer.close
        begin
          # Linux ends a PTY with EIO; retain each chunk before that read.
          loop { output << reader.readpartial(4096) }
        rescue EOFError, Errno::EIO
          nil
        end
        _, status = Process.wait2(pid)
      end
      [output.force_encoding(Encoding::UTF_8).scrub, status.exitstatus]
    end
end
