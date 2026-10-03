require "support/dev_commands"

class DevCommandsTest
  # ---- repairing a halted loop ----

  def test_retry_prints_the_task_it_re_ran_and_sends_the_key_it_was_given
    announce(endpoint: routed_endpoint(
      "POST /loops/retry" => [[200, { "task" => { "key" => "round2", "status" => "waiting" } }]]
    ))

    row = ops(:retry, "al-9", "round2")

    assert_equal "waiting", row.fetch("status")
    assert_match(/^retried:\s+round2$/, @out.string)
    assert_match(/^status:\s+waiting$/, @out.string)
  end

  # RETRY ON ANOTHER MODEL: `--model` (and `--effort` beside it) ride the
  # body to the daemon as themselves — the way a step a provider declined
  # is re-run by a person when no fallback took it; the line names the
  # model the task re-queued on.
  def retry_body(seen) = JSON.parse(seen.grep(%r{\APOST /loops/retry }).last.partition("\r\n\r\n").last)

  def test_retry_model_rides_the_body_and_the_line_names_it
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /loops/retry" => [[200, { "task" => { "key" => "r2", "status" => "waiting" } }]] * 2))

    ops(:retry, "al-9", "r2", model: "dev/fallback", effort: "high")
    assert_equal({ "public_id" => "al-9", "task_key" => "r2", "model" => "dev/fallback",
                   "reasoning_effort" => "high" }, retry_body(seen))
    assert_match(/^retried:\s+r2 on dev\/fallback$/, @out.string)

    reset_out
    ops(:retry, "al-9", "r2")
    assert_equal({ "public_id" => "al-9", "task_key" => "r2" }, retry_body(seen),
      "no flag, no model: the task keeps its selection")
    assert_match(/^retried:\s+r2$/, @out.string)
  end

  # ---- deciding a held call ----

  # THE APPROVAL VERBS: `approve` prints the release and the
  # status the kernel left the row in; `deny` prints the refusal, its
  # reason riding the body when given and NOT when not; a re-park says
  # what to do. The key is never optional.
  def test_approve_prints_the_release_and_deny_prints_the_refusal
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /loops/approve" => [
        [200, { "task" => { "key" => "r1t0", "status" => "dispatched",
                            "approval" => { "origin" => "agent", "decided_by" => "user-1", "decided_at" => "t" } } }],
        [200, { "task" => { "key" => "r1t0", "status" => "needs_approval" } }],
      ],
      "POST /loops/deny" => [
        [200, { "task" => { "key" => "r1t0", "status" => "failed",
                            "error" => { "key" => "approval_denied", "detail" => "use ls" } } }],
        [200, { "task" => { "key" => "r1t0", "status" => "failed", "error" => { "key" => "approval_denied" } } }],
      ]
    ))

    row = ops(:approve, "al-9", "r1t0")
    assert_equal "dispatched", row.fetch("status")
    assert_match(/^approved:\s+r1t0$/, @out.string)
    assert_match(/^status:\s+dispatched$/, @out.string)

    ops(:approve, "al-9", "r1t0")
    assert_match(/^status:\s+needs_approval — the call's effect profile changed under the park; read `rho task` and decide again$/,
      @out.string)

    row = ops(:deny, "al-9", "r1t0", "use ls")
    assert_equal "failed", row.fetch("status")
    assert_match(/^denied:\s+r1t0$/, @out.string)
    assert_match(/^status:\s+failed \(approval_denied\)$/, @out.string)

    ops(:deny, "al-9", "r1t0")
    bodies = seen.grep(/\APOST \/loops\/deny/).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal [{ "public_id" => "al-9", "task_key" => "r1t0", "reason" => "use ls" },
                  { "public_id" => "al-9", "task_key" => "r1t0" }], bodies, "no reason posts none"

    error = assert_raises(Rho::Error) { ops(:approve, "al-9") }
    assert_match(/approve needs LOOP_ID and TASK_KEY/, error.message)
    error = assert_raises(Rho::Error) { ops(:deny, "al-9") }
    assert_match(/deny needs LOOP_ID and TASK_KEY/, error.message)
  end

  # THE SESSION GRANT: `--always`
  # posts the flag and prints the `granted:` line after the decision —
  # the exact text quoted, a prefix with its raw-text warning, a whole
  # tool bare, `already` in words; `--match` alone implies the grant; the
  # matcher prints through the one bound (a control character escaped, the
  # width cut); a kernel refusal prints its line and exits 1 — the call
  # ran, the grant did not land.
  def test_approve_always_prints_the_grant_and_match_implies_it
    seen = []
    task = { "key" => "r1t0", "status" => "dispatched",
             "approval" => { "origin" => "agent", "decided_by" => "user-1", "decided_at" => "t" } }
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /loops/approve" => [
        [200, { "task" => task, "grant" => { "rule" => { "tool" => "bash", "path" => "command", "match" => "npm test",
                                                          "verdict" => "allow" }, "granted_at" => "2026-09-15T10:11:12Z" } }],
        [200, { "task" => task, "grant" => { "rule" => { "tool" => "bash", "path" => "command", "match" => "npm *",
                                                          "verdict" => "allow" }, "granted_at" => "2026-09-15T10:12:40Z" } }],
        [200, { "task" => task, "grant" => { "rule" => { "tool" => "write", "path" => "path", "match" => "/Users/me/project/*",
                                                          "verdict" => "allow" }, "granted_at" => "t" } }],
        [200, { "task" => task, "grant" => { "rule" => { "tool" => "mcp__fs__read_file", "verdict" => "allow" },
                                             "granted_at" => "t" } }],
        [200, { "task" => task, "grant" => { "already" => true } }],
        [200, { "task" => task, "grant" => { "rule" => { "tool" => "bash", "path" => "command",
                                                          "match" => "printf \e[31mx\n#{"y" * 90}", "verdict" => "allow" },
                                             "granted_at" => "t" } }],
        [200, { "task" => task, "grant" => { "refused" => "envelope_bound" } }],
      ]
    ))

    row = ops(:approve, "al-9", "r1t0", always: true)
    assert_equal "dispatched", row.fetch("status")
    assert_equal "approved:  r1t0\nstatus:    dispatched\n" \
                 "granted:   bash  command = \"npm test\"   (this session; `rho rules` lists it)\n", @out.string

    @out.truncate(0)
    @out.rewind
    ops(:approve, "al-9", "r1t0", match: "npm")
    assert_equal "approved:  r1t0\nstatus:    dispatched\n" \
                 "granted:   bash  command = \"npm *\"   (this session; `rho rules` lists it)\n" \
                 "warning:   a prefix grant is raw text — it also allows \"npm anything; …\" on the same line\n", @out.string

    @out.truncate(0)
    @out.rewind
    ops(:approve, "al-9", "r1t0", always: true, match: "/Users/me/project")
    assert_includes @out.string, "granted:   write  path = \"/Users/me/project/*\"   (this session; `rho rules` lists it)\n" \
                                 "warning:   a prefix grant is raw text — it also allows \"/Users/me/project/anything; …\" on the same line\n"

    @out.truncate(0)
    @out.rewind
    ops(:approve, "al-9", "r1t0", always: true)
    assert_equal "approved:  r1t0\nstatus:    dispatched\ngranted:   mcp__fs__read_file\n", @out.string

    @out.truncate(0)
    @out.rewind
    ops(:approve, "al-9", "r1t0", always: true)
    assert_equal "approved:  r1t0\nstatus:    dispatched\ngranted:   (already granted this session)\n", @out.string

    @out.truncate(0)
    @out.rewind
    ops(:approve, "al-9", "r1t0", always: true)
    line = @out.string.lines.fetch(2)
    assert_match(/\Agranted:   bash  command = "printf \\u001B\[31mx\\u000Ay{66}…"   \(this session; `rho rules` lists it\)\n\z/, line)

    @out.truncate(0)
    @out.rewind
    error = assert_raises(Rho::Error) { ops(:approve, "al-9", "r1t0", always: true) }
    assert_equal "approved:  r1t0\nstatus:    dispatched\n" \
                 "granted:   refused — envelope_bound: the call ran; the grant did not land\n", @out.string
    assert_equal "the grant did not land (envelope_bound); the call ran", error.message

    bodies = seen.grep(/\APOST \/loops\/approve/).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal [{ "public_id" => "al-9", "task_key" => "r1t0", "always" => true },
                  { "public_id" => "al-9", "task_key" => "r1t0", "match" => "npm" },
                  { "public_id" => "al-9", "task_key" => "r1t0", "always" => true, "match" => "/Users/me/project" }],
      bodies.first(3), "the flags ride the body as themselves; a plain approve posts neither"
    assert_equal({ "public_id" => "al-9", "task_key" => "r1t0", "always" => true }, bodies.fetch(3))
  end

  # `rho rules`: the session grants numbered,
  # one line each — the shape, the time, the loop, the key, the
  # conversation when there is one — then the declared list's size against
  # the kernel's bound; none says how to add one. Every matcher through
  # the one bound.
  def test_rules_lists_the_session_grants_and_the_declared_size
    announce(endpoint: routed_endpoint(
      "GET /rules" => [
        [200, { "grants" => [
          { "rule" => { "tool" => "bash", "path" => "command", "match" => "npm test", "verdict" => "allow" },
            "loop" => "al-9", "task_key" => "r1t0", "conversation" => "c-1", "granted_at" => "2026-09-15T10:11:12Z" },
          { "rule" => { "tool" => "write", "path" => "path", "match" => "/Users/me/project/*", "verdict" => "allow" },
            "loop" => "al-10", "task_key" => "r2t1", "conversation" => "c-2", "granted_at" => "2026-09-15T10:12:40Z" },
          { "rule" => { "tool" => "stop_process", "verdict" => "allow" },
            "loop" => "al-11", "task_key" => "r1t0", "granted_at" => "2026-09-15T10:13:00Z" },
          { "rule" => { "tool" => "bash", "path" => "command", "match" => "echo \e[0m", "verdict" => "allow" },
            "loop" => "al-12", "task_key" => "r1t0", "conversation" => "c-4", "granted_at" => "2026-09-15T10:14:00Z" },
        ], "declared" => { "rules" => 34, "bytes" => 5120, "bound" => 65_536 } }],
        [200, { "grants" => [], "declared" => { "rules" => 32, "bytes" => 4096, "bound" => 65_536 } }],
      ]
    ))

    document = ops(:rules)
    assert_equal 4, document.fetch("grants").length
    assert_equal <<~TEXT, @out.string
      session grants (until the daemon's next boot):
        1  bash   command = "npm test"   granted 2026-09-15T10:11:12Z on al-9 r1t0 (conversation c-1)
        2  write  path = "/Users/me/project/*"   granted 2026-09-15T10:12:40Z on al-10 r2t1 (conversation c-2)
        3  stop_process   granted 2026-09-15T10:13:00Z on al-11 r1t0
        4  bash   command = "echo \\u001B[0m"   granted 2026-09-15T10:14:00Z on al-12 r1t0 (conversation c-4)
      declared: 34 rules, 5,120 of 65,536 bytes
    TEXT

    @out.truncate(0)
    @out.rewind
    ops(:rules)
    assert_equal <<~TEXT, @out.string
      session grants (until the daemon's next boot):
        (no session grants; rho approve LOOP KEY --always adds one)
      declared: 32 rules, 4,096 of 65,536 bytes
    TEXT
  end

  # The person typed the verb at a halted loop; the daemon reads the trace
  # and uses the kernel's own rule, so no key is sent.
  def test_retry_with_no_key_asks_the_daemon_to_choose
    seen = []
    announce(endpoint: recording_endpoint(seen, 200,
      "task" => { "key" => "round7", "status" => "waiting" }))

    ops(:retry, "al-9")

    assert_match(/^retried:\s+round7$/, @out.string)
    refute_match(/task_key/, seen.join, "no key was typed, so none is sent")
  end

  def test_an_ambiguous_repair_names_both_candidates_and_refuses
    announce(endpoint: routed_endpoint(
      "POST /loops/retry" => [[409, { "error" => { "code" => "ambiguous_repair",
                                                  "message" => "Name one of: round2, round5" } }]]
    ))

    error = assert_raises(Rho::Error) { ops(:retry, "al-9") }

    assert_includes error.message, "round2, round5"
  end

  def test_abandon_prints_the_settlement
    announce(endpoint: routed_endpoint(
      "POST /loops/abandon" => [[200, { "task" => { "key" => "round2", "status" => "failed",
                                                   "failure_resolution" => "abandoned" } }]]
    ))

    row = ops(:abandon, "al-9", "round2")

    assert_equal "abandoned", row.fetch("failure_resolution")
    assert_match(/^abandoned:\s+round2$/, @out.string)
  end

  # GROW A LOOP FROM A TERMINAL: the steps come from a file as the door
  # reads them; the receipt's keys and the new answer print.
  def test_append_reads_the_steps_from_a_file_and_prints_the_receipt
    announce(endpoint: routed_endpoint(
      "POST /loops/append" => [[201, { "receipt" => { "accepted_task_keys" => %w[gate more],
                                                      "steps" => %w[gate more],
                                                      "deliverable_task_key" => "more", "revision" => 2 } }]]
    ))
    file = File.join(Dir.mktmpdir("rho-steps"), "steps.json")
    File.write(file, JSON.generate([{ "ask" => { "key" => "gate", "prompt" => "ok?" } }]))

    receipt = ops(:append, "al-9", file: file)

    assert_equal "more", receipt.fetch("deliverable_task_key")
    assert_match(/^appended:\s+gate, more$/, @out.string)
    assert_match(/^answer:\s+more$/, @out.string)
    assert_raises(Rho::Error) { ops(:append, "al-9") }
    assert_raises(Rho::Error) { ops(:append, "al-9", file: File.join(File.dirname(file), "missing.json")) }
  end

  # THE ANSWER NAMES ITS DOOR: a person reading the line learns
  # whether the agent committed on its own inbox row or the member door
  # answered — the recorded two-door difference, on the terminal.
  def test_answer_prints_the_door
    announce(endpoint: routed_endpoint(
      "POST /answer" => [[200, { "answered" => { "public_id" => "al-9", "task_key" => "ask-1", "door" => "executor" } }],
                         [200, { "answered" => { "public_id" => "al-9", "task_key" => "ask-2", "door" => "member" } }]]
    ))

    ops(:answer, "al-9", "ask-1", "Postgres")
    ops(:answer, "al-9", "ask-2", "Postgres")

    assert_match(/^answered:\s+ask-1 \(executor plane\)$/, @out.string)
    assert_match(/^answered:\s+ask-2 \(member door\)$/, @out.string)
  end

  def test_delete_says_what_it_removed_and_a_live_loop_refuses
    announce(endpoint: routed_endpoint(
      "POST /loops/delete" => [
        [200, { "deleted" => { "public_id" => "al-9" } }],
        [409, { "error" => { "code" => "agent_loop_busy", "message" => "stop it first" } }],
      ]
    ))

    ops(:delete, "al-9")
    assert_match(/^deleted:\s+al-9$/, @out.string)

    error = assert_raises(Rho::Error) { ops(:delete, "al-9") }
    assert_includes error.message, "stop it first"
  end

  # A verb whose route makes a kernel round trip says so to the client it
  # was handed; a local listing does not borrow that budget.
  def test_an_ops_verb_states_the_budget_its_route_needs
    announce(endpoint: routed_endpoint(
      "POST /loops/pause" => [[200, { "loop" => { "public_id" => "al-9", "status" => "paused" } }]],
      "GET /loops" => [[200, { "loops" => [] }]]
    ))

    granted = capture_read_timeouts do
      ops(:pause, "al-9", force: false)
      ops(:loops)
    end

    assert_equal [Rho::Core::Budget::LOCAL.read, Rho::Core::Budget::KERNEL_ROUND_TRIP.read,
                  Rho::Core::Budget::LOCAL.read, Rho::Core::Budget::LOCAL.read], granted,
      "/healthz, the pause, /healthz again, the listing"
  end

  # ---- compact (a repair verb, the extension's) ----

  # ONE HOST-TYPED VERB for compaction: the daemon's core
  # `/compact` route, the key riding only when given, the answer printed by
  # host — the verb lives here, the route stays the core's (the store is).
  def test_compact_posts_to_the_host_route_and_prints_the_repair_it_got
    seen = []
    announce(endpoint: recording_endpoint(seen, 200,
      "compacted" => { "host_type" => "conversation", "public_id" => "c-1", "turn" => "t-1",
                       "turn_kind" => "direct_reply", "task_key" => "r7", "summary_task_key" => "k1" }))

    compacted = ops(:compact, "c-1")

    assert_equal "k1", compacted.fetch("summary_task_key")
    assert_match(%r{\APOST /compact }, seen.grep(%r{/compact}).first)
    refute_match(/task_key/, seen.join, "no key given, none sent")
    assert_match(/^compacted:\s+c-1 \(conversation\)$/, @out.string)
    assert_match(/^task:\s+r7$/, @out.string)
    assert_match(/^summary:\s+k1$/, @out.string)

    seen.clear
    @out.truncate(0)
    announce(endpoint: recording_endpoint(seen, 200,
      "compacted" => { "host_type" => "conversation", "public_id" => "c-1", "turn" => "t-2",
                       "turn_kind" => "compaction_summary" }))
    ops(:compact, "c-1")
    refute_match(/^task:/, @out.string, "idle, the summary turn is the whole answer")

    seen.clear
    announce(endpoint: recording_endpoint(seen, 200,
      "compacted" => { "host_type" => "agent_loop", "public_id" => "al-9", "task_key" => "round3",
                       "summary_task_key" => "k1" }))
    ops(:compact, "al-9", "round3")
    assert_match(/"task_key":"round3"/, seen.join)
    assert_match(/^compacted:\s+al-9 \(agent_loop\)$/, @out.string)

    announce(endpoint: recording_endpoint(seen, 409,
      "error" => { "code" => "task_not_queued", "message" => "The running turn has no round left to compact" }))
    error = assert_raises(Rho::Error) { ops(:compact, "c-1") }
    assert_match(/no round left/, error.message)
  end
end
