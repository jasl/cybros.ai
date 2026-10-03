require "support/dev_commands"

class DevCommandsTest
  def test_stop_defaults_to_conversation_and_can_name_an_exact_old_loop
    seen = []
    announce(endpoint: recording_routed_endpoint(seen, "POST /stop" => [[200,
      { "stopped" => { "host_type" => "conversation", "public_id" => "c-child", "status" => "canceling" } }]]))

    ops(:stop, "c-child")
    ops(:stop, "al-old", "r1", "host-type": "agent_loop", graceful: true)
    bodies = seen.grep(%r{\APOST /stop }).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal [
      { "public_id" => "c-child", "force" => true, "host_type" => "conversation" },
      { "public_id" => "al-old", "task_key" => "r1", "force" => false, "host_type" => "agent_loop" },
    ], bodies
  end

  def test_activate_selects_the_named_candidate_and_reports_it
    seen = []
    document = { "variant" => { "public_id" => "v-old", "active" => true } }
    announce(endpoint: recording_routed_endpoint(seen, "POST /conversations/activate" => [[200, document]]))

    assert_equal document.fetch("variant"), ops(:activate, "c-1", "t-1", "v-old")
    assert_equal "variant:   v-old active\n", @out.string
    assert_equal({ "public_id" => "c-1", "turn" => "t-1", "variant" => "v-old" },
      JSON.parse(seen.grep(%r{\APOST /conversations/activate }).last.partition("\r\n\r\n").last))
  end

  def test_activate_requires_the_conversation_turn_and_candidate
    [[], ["c-1"], ["c-1", "t-1"]].each do |args|
      error = assert_raises(Rho::Error) { ops(:activate, *args) }
      assert_includes error.message, "CONVERSATION_ID, TURN and VARIANT"
    end
  end

  # ---- rho inputs ----

  # THE QUEUE FROM A TERMINAL: `rho inputs ID` lists the rows so a
  # person can find a parked one — state, kind, the words — then `rm`
  # drops it and `edit` rewrites it (the unblock path); the subword is
  # the first argument, and any other word is refused before the wire.
  def test_inputs_lists_the_queue_then_drops_and_rewrites_a_row
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /inputs?public_id=c-1" => [[200, { "host_public_id" => "c-1", "inputs" => [
        { "public_id" => "cin-1", "queue_position" => 0, "state" => "blocked", "kind" => "direct_reply",
          "text" => "push it", "blocked_reason" => "unknown_model", "origin" => "person" },
        { "public_id" => "cin-2", "queue_position" => 1, "state" => "pending", "kind" => "message", "text" => "and then",
          "origin" => "agent" },
        { "public_id" => "cin-3", "queue_position" => 2, "state" => "pending", "kind" => "direct_reply",
          "text" => "what is this?", "origin" => "person",
          "attachments" => [{ "public_id" => "up-1", "filename" => "diagram.png", "content_type" => "image/png",
                              "byte_size" => 188_416 }] },
      ] }], [200, { "host_public_id" => "c-1", "inputs" => [] }]],
      "POST /inputs/delete" => [[200, { "deleted" => { "public_id" => "cin-1", "host_public_id" => "c-1" } }]],
      "POST /inputs/update" => [[200, { "input" => { "public_id" => "cin-1", "state" => "pending", "text" => "again" } }]]
    ))

    rows = ops(:inputs, "c-1")
    assert_equal %w[cin-1 cin-2 cin-3], rows.map { |row| row["public_id"] }
    assert_match(/^  blocked    cin-1  direct_reply  "push it"  \(unknown_model\)$/, @out.string, @out.string)
    assert_match(/^  pending    cin-2  message  "and then"  \[agent\]$/, @out.string,
      "a peer's row shows its kind; a person's own word carries no suffix")
    assert_match(%r{^  pending    cin-3  direct_reply  "what is this\?"  attachments: diagram\.png \(image/png, 184 KiB\)$},
      @out.string, "the pictures a row carries, as the kernel describes them")

    ops(:inputs, "rm", "c-1", "cin-1")
    assert_match(/^removed:\s+cin-1$/, @out.string)
    ops(:inputs, "edit", "c-1", "cin-1", "again")
    assert_match(/^edited:\s+cin-1 \(pending\)$/, @out.string)
    bodies = seen.grep(%r{\APOST /inputs/}).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal [{ "public_id" => "c-1", "input_public_id" => "cin-1" },
                  { "public_id" => "c-1", "input_public_id" => "cin-1", "text" => "again" }], bodies

    @out.truncate(0)
    @out.rewind
    assert_empty ops(:inputs, "c-1")
    assert_match(/\(the queue is empty\)/, @out.string)

    error = assert_raises(Rho::Error) { ops(:inputs, "zap", "c-1", "cin-1") }
    assert_match(/rm or edit/, error.message)
    assert_raises(Rho::Error) { ops(:inputs, "rm", "c-1") }
    assert_raises(Rho::Error) { ops(:inputs, "edit", "c-1", "cin-1") }
  end

  # `rho inputs edit ID INPUT [TEXT] --at TIME | --in DURATION | --now` and
  # the listing's `at <time>`: the
  # two flags are the kernel's two fields as typed, a naive `--at` is this
  # terminal's zone sent in UTC, `--now` is the typed clear (`deliver_in:
  # "0s"`), TEXT is optional beside a time flag, and one flag at a time.
  def test_inputs_edit_reschedules_with_at_or_in_clears_with_now_and_the_listing_shows_the_time
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /inputs?public_id=c-1" => [[200, { "host_public_id" => "c-1", "inputs" => [
        { "public_id" => "cin-4", "queue_position" => 0, "state" => "pending", "kind" => "direct_reply",
          "text" => "check the deploy", "origin" => "person", "deliver_at" => "2026-09-16T09:00:00Z" },
      ] }]],
      "POST /inputs/update" => [[200, { "input" => { "public_id" => "cin-4", "state" => "pending",
                                                     "deliver_at" => "2026-09-16T09:20:00Z" } }]]
    ))

    ops(:inputs, "c-1")
    assert_match(/^  pending    cin-4  direct_reply  "check the deploy"  at 2026-09-16T09:00:00Z$/, @out.string,
      @out.string)

    ops(:inputs, "edit", "c-1", "cin-4", in: "20m")
    assert_match(/^edited:\s+cin-4 \(pending, scheduled for 2026-09-16T09:20:00Z\)$/, @out.string)
    ops(:inputs, "edit", "c-1", "cin-4", "sooner", at: "2026-09-16T09:00:00+08:00")
    ops(:inputs, "edit", "c-1", "cin-4", at: "2026-09-16T09:00:00")
    ops(:inputs, "edit", "c-1", "cin-4", now: true)
    bodies = seen.grep(%r{\APOST /inputs/update}).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal [
      { "public_id" => "c-1", "input_public_id" => "cin-4", "deliver_in" => "20m" },
      { "public_id" => "c-1", "input_public_id" => "cin-4", "text" => "sooner", "deliver_at" => "2026-09-16T09:00:00+08:00" },
      { "public_id" => "c-1", "input_public_id" => "cin-4", "deliver_at" => Time.iso8601("2026-09-16T09:00:00").utc.iso8601 },
      { "public_id" => "c-1", "input_public_id" => "cin-4", "deliver_in" => "0s" },
    ], bodies, "the kernel's two fields as typed; a naive --at in this terminal's zone; --now is the typed clear"

    error = assert_raises(Rho::Error) { ops(:inputs, "edit", "c-1", "cin-4", in: "20m", now: true) }
    assert_match(/one of/, error.message)
    error = assert_raises(Rho::Error) { ops(:inputs, "edit", "c-1", "cin-4", at: "tomorrow") }
    assert_match(/\Adeliver_at_invalid: /, error.message)
    assert_equal 4, seen.grep(%r{\APOST /inputs/update}).length, "a refusal here reaches no daemon"
  end

  # A SCHEDULED ROW on the pushed channel: its own line with
  # the time the kernel holds, whatever the origin — a person's own word
  # included.
  def test_follow_prints_a_scheduled_row_with_its_time_whatever_the_origin
    daemon = boot
    state = { complete: false }
    listeners = Queue.new
    hold_run(daemon, followed_run("c-1", state: state, listeners: listeners, tasks: []))

    follower = Thread.new { ops(:follow, "c-1") }
    handler = listeners.pop
    handler.call(Struct.new(:type, :payload).new("input_accepted",
      { "input_public_id" => "cin-4", "origin" => "person", "deliver_at" => "2026-09-16T09:20:00Z" }))
    state[:complete] = true
    handler.call(Struct.new(:type, :payload).new("input_accepted",
      { "input_public_id" => "cin-5", "origin" => "agent", "sender_conversation_public_id" => "c-peer",
        "deliver_at" => "2026-09-16T10:00:00Z" }))

    assert follower.join(10), "follow never returned"
    assert_match(/^scheduled: cin-4 for 2026-09-16T09:20:00Z$/, @out.string, @out.string)
    assert_match(/^scheduled: cin-5 for 2026-09-16T10:00:00Z$/, @out.string)
  end

  def test_inputs_carries_the_kernels_refusal_on_a_kernel_origin_row
    announce(endpoint: routed_endpoint(
      "POST /inputs/delete" => [[409, { "error" => { "code" => "kernel_input_immutable",
                                                     "message" => "A kernel-origin input is not editable" } }]]
    ))

    error = assert_raises(Rho::Error) { ops(:inputs, "rm", "c-1", "cin-k") }
    assert_includes error.message, "not editable"
  end

  # ---- rho conversation participants ----

  # WHO MAY SEE A CONVERSATION, from the terminal: the bare verb prints the
  # default and one line per named principal (level, id, kind, name); add,
  # rm and default each PUT ONE change to the daemon's one route, whose
  # answer is the whole carrier as it now stands; the subword grammar is
  # refused before the wire.
  def test_conversation_participants_prints_the_carrier_and_re_cuts_it_through_one_put
    seen = []
    listed = { "conversation" => { "public_id" => "c-1" }, "access" => { "default" => "none", "entries" => [
      { "user_public_id" => "u-steward", "handle" => "steward", "kind" => "human", "display_name" => "Steward",
        "level" => "full" },
      { "user_public_id" => "u-peer", "handle" => "peer", "kind" => "agent", "display_name" => "Peer", "level" => "read" },
    ] } }
    announce(endpoint: recording_routed_endpoint(seen, "PUT /conversations/access" => [[200, listed]]))

    access = ops(:conversation, "participants", "c-1")
    assert_equal "none", access.fetch("default")
    assert_match(/^default:\s+none$/, @out.string)
    assert_match(/^  full  @steward  u-steward  human  Steward$/, @out.string, @out.string)
    assert_match(/^  read  @peer  u-peer  agent  Peer$/, @out.string, @out.string)

    ops(:conversation, "participants", "c-1", "add", "@peer", "full")
    ops(:conversation, "participants", "c-1", "rm", "u-peer")
    ops(:conversation, "participants", "c-1", "default", "read")
    bodies = seen.grep(%r{\APUT /conversations/access}).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal [
      { "public_id" => "c-1" },
      { "public_id" => "c-1", "change" => { "op" => "add", "principal" => "@peer", "level" => "full" } },
      { "public_id" => "c-1", "change" => { "op" => "rm", "principal" => "u-peer" } },
      { "public_id" => "c-1", "change" => { "op" => "default", "level" => "read" } },
    ], bodies, "a principal is `@handle` or a public id, relayed as typed"

    error = assert_raises(Rho::Error) { ops(:conversation, "members", "c-1") }
    assert_match(/participants/, error.message)
    assert_raises(Rho::Error) { ops(:conversation, "participants") }
    error = assert_raises(Rho::Error) { ops(:conversation, "participants", "c-1", "zap", "u-peer") }
    assert_match(/add, rm or default/, error.message)
    assert_raises(Rho::Error) { ops(:conversation, "participants", "c-1", "add", "u-peer") }
    assert_raises(Rho::Error) { ops(:conversation, "participants", "c-1", "rm") }
    assert_raises(Rho::Error) { ops(:conversation, "participants", "c-1", "default") }
    assert_equal 4, seen.grep(%r{\APUT /conversations/access}).length, "a refused grammar never reaches the wire"
  end

  def test_conversation_participants_prints_an_empty_set_and_relays_the_kernels_refusal
    announce(endpoint: routed_endpoint(
      "PUT /conversations/access" => [[200, { "conversation" => { "public_id" => "c-1" },
                                              "access" => { "default" => "full", "entries" => [] } }],
                                      [403, { "error" => { "code" => "not_authorized",
                                                           "message" => "This workspace is not writable by the caller" } }]]
    ))

    ops(:conversation, "participants", "c-1")
    assert_match(/^\(no named participants\)$/, @out.string)
    error = assert_raises(Rho::Error) { ops(:conversation, "participants", "c-1", "default", "none") }
    assert_includes error.message, "not writable"
  end

  # ---- btw / side ----

  SIDE_STREAM = "event: snapshot\ndata: {\"public_id\":\"c-1-side\",\"tasks\":[],\"text\":\"reading\",\"text_length\":7}\n\n" \
                "event: task_status\ndata: {\"task_key\":\"r1\",\"status\":\"completed\"}\n\n" \
                "event: text_delta\ndata: {\"text\":\" lib/a.rb\"}\n\n" \
                "event: turn_status\ndata: {\"status\":\"completed\"}\n\n" \
                "event: closed\ndata: {\"reason\":\"turn_settled\"}\n\n".freeze

  # `rho btw QUESTION`: one `/side` with the question under the `none`
  # posture (the parent's tools declared, every park denied — the
  # daemon's, `daemon/loops_test.rb`), then the side's stream printed as
  # plain text and NOTHING else — no task table, no status line, no
  # "(stream ended" — a person asked a question beside the work and gets
  # the answer delivered. `--on ID` names the parent.
  def test_btw_asks_on_the_side_and_prints_the_answer_alone
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /side" => [[201, { "side" => { "public_id" => "c-1-side" }, "parent" => { "public_id" => "c-1" },
                               "reused" => false, "turn" => { "public_id" => "t-1" }, "loop" => { "public_id" => "al-1" } }]],
      "GET /loops/follow?public_id=c-1-side" => [[200, SIDE_STREAM]]
    ))

    answer = ops(:btw, "which file?", on: "c-1")

    assert_equal "c-1-side", answer.dig("side", "public_id")
    assert_equal ["#{Rho::StreamPrinter::INDENT}reading lib/a.rb"], @out.string.lines.map(&:chomp), @out.string
    body = JSON.parse(seen.grep(%r{\APOST /side}).first.partition("\r\n\r\n").last)
    assert_equal({ "parent_public_id" => "c-1", "text" => "which file?", "tools" => "none" }, body)
  end

  def test_btw_without_on_names_no_parent_and_needs_a_question
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /side" => [[201, { "side" => { "public_id" => "c-1-side" }, "parent" => { "public_id" => "c-1" },
                               "reused" => false, "pending" => true }]],
      "GET /loops/follow?public_id=c-1-side" => [[200, SIDE_STREAM]]
    ))

    ops(:btw, "which file?")
    body = JSON.parse(seen.grep(%r{\APOST /side}).first.partition("\r\n\r\n").last)
    assert_equal({ "text" => "which file?", "tools" => "none" }, body, "the daemon picks the newest conversation")
    assert_raises(Rho::Error) { ops(:btw, " ") }
  end

  # `rho side [ID]` opens or resumes the parent's one open side with rho's
  # read-only posture and prints its id, its parent and the sentence the
  # model reads; the person then talks in it with `rho say <side-id>`.
  def test_side_opens_or_resumes_the_open_side_and_prints_how_to_talk_in_it
    seen = []
    lead = Rho::Daemon::Loops::SIDE_LEADS.fetch("read")
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /side" => [[201, { "side" => { "public_id" => "c-1-side" }, "parent" => { "public_id" => "c-1" },
                               "reused" => false, "lead" => lead }],
                       [200, { "side" => { "public_id" => "c-1-side" }, "parent" => { "public_id" => "c-1" },
                               "reused" => true, "lead" => lead }]]
    ))

    answer = ops(:side)
    assert_equal "c-1-side", answer.dig("side", "public_id")
    assert_equal ["side:      c-1-side (opened)", "parent:    c-1", "lead:      #{lead}",
                  "talk:      rho say c-1-side \"…\""], @out.string.lines.map(&:chomp), @out.string

    @out.truncate(0)
    @out.rewind
    ops(:side, "c-1")
    assert_match(/^side:\s+c-1-side \(open\)$/, @out.string)
    bodies = seen.grep(%r{\APOST /side}).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal [{ "tools" => "read" }, { "parent_public_id" => "c-1", "tools" => "read" }], bodies
  end

  def test_btw_and_side_carry_the_daemons_refusal
    announce(endpoint: routed_endpoint(
      "POST /side" => [[404, { "error" => { "code" => "host_not_followed", "message" => "This daemon is not following c-nope" } }]]
    ))

    error = assert_raises(Rho::Error) { ops(:btw, "hi", on: "c-nope") }
    assert_includes error.message, "not following c-nope"
    assert_raises(Rho::Error) { ops(:side, "c-nope") }
  end

  # `rho loops --side` lists the side rows the default listing hides, each
  # with its parent.
  def test_loops_side_lists_the_side_rows_with_their_parent
    announce(endpoint: routed_endpoint(
      "GET /loops?side=1" => [[200, { "loops" => [
        { "public_id" => "c-1-side", "status" => "completed", "side" => { "parent" => "c-1" } },
      ] }]]
    ))

    rows = ops(:loops, side: true)

    assert_equal %w[c-1-side], rows.map { |row| row["public_id"] }
    assert_match(/^c-1-side  completed  side of c-1$/, @out.string, @out.string)
  end

  # THE PROMPTLESS OPEN: `do` with no PROMPT prints
  # the conversation, the create-door lines the answer carries (the
  # access default, the answerer, the runner slot — the shape `do`'s
  # turn answer prints) and the verb that speaks in it; nothing a turn
  # carries.
  def test_do_without_a_prompt_prints_the_conversation_and_how_to_speak_in_it
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /conversations" => [[201, { "conversation" => { "public_id" => "c-9" }, "access" => "none",
                                        "answered_by" => { "public_id" => "peer-1", "handle" => "lark" }, "runner" => nil }]]))

    answer = ops(:do, nil, restricted: true, agent: "@lark")

    assert_equal "c-9", answer.dig("conversation", "public_id")
    assert_equal ["conversation: c-9", "access:       none (restricted)", "agent:        @lark (peer-1)",
                  "runner:       #{Rho::RunnerSlot::NONE}", "next:         rho say c-9 \"…\""], lines, @out.string
    body = JSON.parse(seen.grep(%r{\APOST /conversations}).first.partition("\r\n\r\n").last)
    refute body.key?("prompt")
    assert_equal ["@lark", "none"], body.values_at("agent", "access_default")
  end

  # `say` PRINTS THE TURN AND THE LOOP it opened after
  # the queued row — or `pending:` past the daemon's bound — and nothing
  # of either on a loop host's answer; `--approval`/`--model` ride the body.
  # A ROW THE KERNEL PARKED is not a failure of the
  # verb: the daemon answers 200 with the parked row, and the verb prints
  # the reason word and the two verbs that act on the queue, exit 0.
  def test_say_prints_the_turn_and_loop_it_opened_or_pending_and_sends_the_two_flags
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /say" => [[200, { "input" => { "public_id" => "cin-2", "state" => "pending" },
                              "turn" => { "public_id" => "t-2" }, "loop" => { "public_id" => "al-2" } }],
                      [200, { "input" => { "public_id" => "cin-3", "state" => "pending" }, "pending" => true }],
                      [200, { "input" => { "public_id" => "cin-4", "state" => "steering" } }],
                      [200, { "input" => { "public_id" => "cin-5", "state" => "blocked", "blocked_reason" => "provider_disabled" },
                              "pending" => true, "blocked" => "provider_disabled" }],
                      [200, { "input" => { "public_id" => "cin-6", "state" => "steering" }, "pending" => true }],
                      [200, { "input" => { "public_id" => "cin-7", "state" => "pending" }, "pending" => true,
                              "compaction" => { "turn" => { "public_id" => "t-s" }, "loop" => { "public_id" => "al-s" } } }]]))

    ops(:say, "c-9", "next", mode: "queue", approval: "rules", model: "m/y")
    assert_equal ["queued:    cin-2 (pending)", "turn:      t-2", "loop:      al-2"], lines, @out.string
    body = JSON.parse(seen.grep(%r{\APOST /say}).first.partition("\r\n\r\n").last)
    assert_equal ["rules", "m/y"], body.values_at("approval_mode", "model")

    reset_out
    ops(:say, "c-9", "later", mode: "queue")
    assert_equal ["queued:    cin-3 (pending)", "pending:   the turn has not started yet; `rho watch` follows it"], lines
    body = JSON.parse(seen.grep(%r{\APOST /say}).last.partition("\r\n\r\n").last)
    refute body.key?("approval_mode"), "no flag sends no key"
    refute body.key?("model")

    reset_out
    ops(:say, "al-9", "steer")
    assert_equal ["queued:    cin-4 (steering)"], lines, "a loop host names no turn"

    reset_out
    answer = ops(:say, "c-9", "blocked?", mode: "queue")
    assert_equal ["queued:    cin-5 (blocked)",
                  "blocked:   provider_disabled — the input is parked at its position; `rho inputs c-9` lists it, " \
                  "`rho inputs rm c-9 cin-5` drops it"], lines, @out.string
    assert_equal "provider_disabled", answer.fetch("blocked"), "the document is answered, not raised"

    # A conversation STEER: `pending` under the
    # kernel's `steering` — the words joined the turn in flight, so the
    # line under the row says so, never "not started".
    reset_out
    ops(:say, "c-9", "and this")
    assert_equal ["queued:    cin-6 (steering)", "pending:   the words joined the turn in flight; `rho watch` follows it"],
      lines, @out.string

    # BEHIND THE KERNEL'S BETWEEN-TURN SUMMARY: the
    # daemon names the summary's ids under `compaction`, and the line
    # says what runs first — its loop as what it is, never as `loop:`,
    # which a lane would follow into the summarizer.
    reset_out
    ops(:say, "c-9", "after the summary", mode: "queue")
    assert_equal ["queued:    cin-7 (pending)",
                  "pending:   the turn has not started yet; a compaction summary runs first (loop al-s); `rho watch` follows it"],
      lines, @out.string
  end

  # `rho turns ID`: one line per turn — the
  # position, the id, the role, the kind, the status, the backing loop
  # when the reply minted one, the words WHOLE (the spine is the replay's, and a line that cut the words at a width hid the ones a lane looks for), under a reply turn the `said:` line —
  # the words that OPENED it, the variant's `prompt_text`, folded whole, no line when the seed carried none — and
  # the next window's verb when more stands past the cap; `--json`
  # prints the document whole.
  def test_turns_prints_one_line_per_turn_and_the_next_window
    long_words = "fix the build\nplease — #{"the whole reply rides the line, " * 4}every word of it, second words"
    document = {
      "turns" => [
        { "public_id" => "t-0", "position" => 0, "kind" => "message", "role" => "user", "status" => "completed",
          "origin" => "person", "active_variant" => { "content" => long_words, "source" => "manual" } },
        { "public_id" => "t-1", "position" => 1, "kind" => "direct_reply", "role" => "assistant", "status" => "completed",
          "origin" => "person",
          "active_variant" => { "content" => "done", "prompt_text" => "fix the\nbuild  please",
                                "agent_loop_public_id" => "al-1", "source" => "agent_loop" } },
        { "public_id" => "t-2", "position" => 2, "kind" => "direct_reply", "role" => "assistant", "status" => "failed",
          "origin" => "person" },
      ],
      "pagination" => { "after_position" => 2, "has_more" => true },
    }
    # The narrower key first: the table matches a request line by prefix.
    # A window past the last turn is answered as the daemon answers an
    # empty page: no rows, no position, nothing more.
    past_the_end = { "turns" => [], "pagination" => { "after_position" => nil, "has_more" => false } }
    announce(endpoint: routed_endpoint(
      "GET /conversations/turns?public_id=c-9&after_position=2&limit=1" => [[200, past_the_end]],
      "GET /conversations/turns?public_id=c-9" => [[200, document]]))

    answer = ops(:turns, "c-9")

    assert_equal document, answer
    assert_equal ["   0  t-0  user  message  completed  \"#{long_words.gsub(/\s+/, " ")}\"",
                  "   1  t-1  assistant  direct_reply  completed  loop al-1  \"done\"",
                  "      said: \"fix the build please\"",
                  "   2  t-2  assistant  direct_reply  failed",
                  "more:      rho turns c-9 --after 2"], lines, @out.string

    reset_out
    ops(:turns, "c-9", after: 2, limit: 1)
    assert_equal ["(no turns past position 2)"], lines, "nothing past the end, so no next window"

    reset_out
    ops(:turns, "c-9", json: true)
    assert_equal document, JSON.parse(@out.string)
  end

  # `rho attach ID --conversation`: the conversation
  # arm's body, and one line naming what is followed now.
  def test_attach_conversation_follows_the_conversation_and_prints_it
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /loops/attach" => [[200, { "conversation" => { "public_id" => "c-9" }, "run" => { "public_id" => "c-9" } }]]))

    answer = ops(:attach, "c-9", conversation: true, live: false)

    assert_equal "c-9", answer.dig("conversation", "public_id")
    assert_equal ["c-9  conversation  followed"], lines
    body = JSON.parse(seen.grep(%r{\APOST /loops/attach}).first.partition("\r\n\r\n").last)
    assert_equal({ "public_id" => "c-9", "live" => false, "host_type" => "conversation" }, body)
  end

  # ---- rewind / regenerate ----

  def rewind_answer(world)
    { "rewind" => { "conversation" => "c-1-side", "forked_from" => "t0", "position" => 0, "world" => world } }
  end

  def test_rewind_needs_a_conversation_and_a_turn
    assert_raises(Rho::Error) { ops(:rewind, {}) }
    assert_raises(Rho::Error) { ops(:rewind, "c-1", {}) }
  end

  def test_regenerate_needs_a_conversation_and_a_turn
    assert_raises(Rho::Error) { ops(:regenerate, {}) }
    assert_raises(Rho::Error) { ops(:regenerate, "c-1", {}) }
  end

  def test_rewind_prints_the_child_the_turn_and_what_the_restore_did
    world = { "status" => "restored", "checkpoint" => "H1", "undo" => "H3" }
    announce(endpoint: routed_endpoint("POST /conversations/rewind" => [[200, rewind_answer(world)]]))

    ops(:rewind, "c-1", "t0")

    assert_equal ["conversation: c-1-side", "forked_from:  t0 (position 0)", "world:        restored H1 (undo H3)"],
      @out.string.lines.map(&:chomp)
  end

  def test_rewind_exits_non_zero_when_the_world_could_not_be_restored
    world = { "status" => "failed", "reason" => "checkpoint_unknown" }
    announce(endpoint: routed_endpoint("POST /conversations/rewind" => [[200, rewind_answer(world)]]))

    error = assert_raises(Rho::Error) { ops(:rewind, "c-1", "t0") }
    assert_match(/could not be restored: checkpoint_unknown/, error.message)
    assert_match(/^world:        failed: checkpoint_unknown$/, @out.string, "the child exists; the line says so first")
  end

  def test_regenerate_prints_the_turn_the_new_candidate_and_the_restore
    document = { "regenerate" => { "turn" => "t3", "variant" => "v-new",
                                   "world" => { "status" => "restored", "checkpoint" => "H2", "undo" => "H4" } } }
    announce(endpoint: routed_endpoint("POST /conversations/regenerate" => [[200, document]]))

    ops(:regenerate, "c-1", "t3")

    assert_equal ["turn:      t3", "variant:   v-new", "world:     restored H2 (undo H4)"],
      @out.string.lines.map(&:chomp)
  end

  def test_regenerate_prints_the_undo_and_exits_non_zero_when_the_door_refused_after_the_restore
    document = { "regenerate" => { "turn" => "t3", "variant" => nil,
                                   "world" => { "status" => "restored", "checkpoint" => "H2", "undo" => "H4",
                                                "door_refused" => "conversation_busy" } } }
    announce(endpoint: routed_endpoint("POST /conversations/regenerate" => [[200, document]]))

    error = assert_raises(Rho::Error) { ops(:regenerate, "c-1", "t3") }
    assert_match(/restored \(undo H4\) but the door refused: conversation_busy/, error.message)
  end

  # The one renderer both verbs share, every outcome the wire carries.
  def test_world_line_renders_each_outcome
    line = ->(world) { Rho::Dev::Conversations.send(:world_line, world) }

    assert_equal "restored H1 (undo H3)", line.call("status" => "restored", "checkpoint" => "H1", "undo" => "H3")
    assert_equal "restored H1 (undo H3) [outside the root: /x]",
      line.call("status" => "restored", "checkpoint" => "H1", "undo" => "H3", "outside" => ["/x"])
    # An ignored path the store never held is printed too.
    assert_equal "restored H1 (undo H3) [ignored: secrets/.env]",
      line.call("status" => "restored", "checkpoint" => "H1", "undo" => "H3", "ignored" => ["secrets/.env"])
    assert_equal "restored H1 (undo H3) [outside the root: /x] [ignored: a, b]",
      line.call("status" => "restored", "checkpoint" => "H1", "undo" => "H3", "outside" => ["/x"],
        "ignored" => %w[a b])
    assert_equal "untouched", line.call("status" => "untouched")
    assert_equal "kept", line.call("status" => "kept")
    assert_equal "unavailable: runner_mismatch", line.call("status" => "unavailable", "reason" => "runner_mismatch")
    assert_equal "unavailable: no_checkpoint (skipped: tree_too_large)",
      line.call("status" => "unavailable", "reason" => "no_checkpoint", "skipped" => "tree_too_large")
    assert_equal "unavailable: no_checkpoint", line.call("status" => "unavailable", "reason" => "no_checkpoint")
    assert_equal "failed: restore_failed (undo H3)",
      line.call("status" => "failed", "reason" => "restore_failed", "undo" => "H3")
  end
end
