require "support/daemon_run_helpers"

class DaemonHostFollowersTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  # THE HOST-TYPED VERBS: `/say` and `/stop` are keyed by
  # a followed host's id — here a standalone run Ops placed — and reach
  # that host's own door: a `message` through the run door with the mode
  # the caller chose, and the run's own stop verb.
  def test_say_speaks_through_a_run_hosts_door_with_its_mode
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)
    store.remember(run_host("al-1"), workspace: "ws-1")

    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "al-1", text: "look at the tests" })
    assert_equal "200", response.code, response.body
    assert_equal({ "public_id" => "in-1", "state" => "steering", "position" => { "cursor" => nil, "sequence" => 0 } }, JSON.parse(response.body).fetch("input"))
    assert_equal({ "kind" => "message", "text" => "look at the tests", "delivery_mode" => "steer" },
      api.run_inputs.fetch(0).fetch("input"))
    assert(api.requests.any? { |path, _| path.end_with?("/runs/al-1/inputs") },
      "the words went through the RUN door: #{api.requests.map(&:first).inspect}")

    queued = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "al-1", text: "and then", delivery_mode: "queue" })
    assert_equal "pending", JSON.parse(queued.body).dig("input", "state")
    assert_equal "queue", api.run_inputs.fetch(1).dig("input", "delivery_mode")

    immediate = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "al-1", text: "read this while the command runs", delivery_mode: "steer_now" })
    assert_equal "200", immediate.code, immediate.body
    assert_equal "steer_now", api.run_inputs.fetch(2).dig("input", "delivery_mode")

    assert_equal "400", request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "al-1", text: "x", delivery_mode: "later" }).code
    assert_equal "400", request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "al-1", text: " " }).code
  end

  def test_conversation_send_now_keeps_its_text_mode_and_target_without_stopping_work
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1", model: "openrouter/x")

    response = request(daemon, :post, "/say", token: bearer(daemon), body: {
      public_id: "c-1", text: "Use the shorter output", delivery_mode: "steer_now", wait: false,
      expected_steering_run_public_id: "al-1",
    })

    assert_equal "200", response.code, response.body
    assert_equal "steering", JSON.parse(response.body).dig("input", "state")
    input = api.conversation_inputs.last.fetch("input")
    assert_equal ["Use the shorter output", "steer_now", "al-1"], input.values_at("text", "delivery_mode", "expected_steering_run_public_id")
    refute api.requests.any? { |path, _| path.end_with?("/stop", "/cancel") }
  end

  # `rho say --in|--at`: the two
  # fields pass through `say_fields` to the conversation host's door as the
  # kernel's own words — the daemon parses neither; a run host has one
  # turn in flight and refuses them before the call; the answer carries the
  # row's `deliver_at` so the terminal prints it.
  def test_say_passes_deliver_in_and_deliver_at_to_the_conversation_door_and_a_run_host_refuses_them
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1", model: "openrouter/x")

    said = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "c-1", text: "check the deploy", delivery_mode: "queue", deliver_in: "20m" })
    assert_equal "200", said.code, said.body
    input = api.conversation_inputs.last.fetch("input")
    assert_equal "20m", input.fetch("deliver_in"), "the delay as typed: the kernel parses it"
    refute input.key?("deliver_at")
    assert_equal "queue", input.fetch("delivery_mode")
    assert_equal "2026-09-16T09:20:00Z", JSON.parse(said.body).dig("input", "deliver_at"),
      "the row's time, as the kernel answered it"

    said = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "c-1", text: "later", delivery_mode: "queue", deliver_at: "2026-09-16T09:00:00Z" })
    assert_equal "200", said.code, said.body
    assert_equal "2026-09-16T09:00:00Z", api.conversation_inputs.last.dig("input", "deliver_at")
    refute api.conversation_inputs.last.fetch("input").key?("deliver_in")

    store.remember(run_host("al-solo"), workspace: "ws-1")
    refused = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "al-solo", text: "x", delivery_mode: "queue", deliver_in: "20m" })
    assert_equal "400", refused.code, refused.body
    assert_match(%r{drop --at/--in}, JSON.parse(refused.body).dig("error", "message"))
    assert_empty api.run_inputs, "nothing reached the run door"
  end

  # On a CONVERSATION the words are a `direct_reply` on the model the row
  # remembers — keyed by the conversation's id or its backing run's — and
  # a host whose run ended is followed again before the words are posted,
  # so the turn they start has a watcher.
  def test_say_on_a_conversation_posts_a_direct_reply_on_the_remembered_model_and_re_follows
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    # The queued word below awaits a run the fake never mints past `al-1`:
    # the bound is the injected clock's, not real seconds.
    now = Time.utc(2026, 9, 6)
    daemon = member_ready(boot(clock: -> { now += Rho::Daemon::HostFollowers::MATERIALIZATION_POLL },
      sleeper: ->(_seconds) { sleep 0.001 }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1", model: "openrouter/x")
    assert_empty daemon.lineage.followers

    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "al-1", text: "also the docs" })

    assert_equal "200", response.code, response.body
    assert_equal({ "public_id" => "cin-1", "state" => "steering", "position" => { "cursor" => nil, "sequence" => 0 } }, JSON.parse(response.body).fetch("input"))
    input = api.conversation_inputs.fetch(0).fetch("input")
    assert_equal({ "kind" => "direct_reply", "text" => "also the docs", "delivery_mode" => "steer",
                   "model" => { "model" => "openrouter/x" } }, input.except("inline"))
    # The lead rides this say too (every plain turn, not only one whose runner or root set moved) — a row remembered by
    # hand carries this machine's local lead.
    assert_includes input.dig("inline", 0, "text"), "- code:", "the Agent lead rides every say without a Runner"
    assert_equal ["c-1"], daemon.lineage.followers.map(&:public_id), "re-adopted before the words were posted"

    queued = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "c-1", text: "later", delivery_mode: "queue" })
    assert_equal "pending", JSON.parse(queued.body).dig("input", "state")
    assert_equal 1, daemon.lineage.followers.length, "a standing run is not doubled"
  end

  # `say` ANSWERS THE TURN AND THE RUN: the follow route closes at once on a run whose last turn settled,
  # so a reader joining on `say`'s answer alone read the PREVIOUS turn.
  # Now `say` waits for the run the kernel mints for THIS input — the
  # same await `do` and a side's question run, barred on the run the run
  # held before the words went out — and answers `turn`/`run` beside the
  # input. THE TWO BODY FIELDS: `model` rides ahead of the
  # daemon's own resolution and is remembered on the row; `approval_mode`
  # is the turn's tightening in the kernel's vocabulary, refused by name
  # outside it. The page is the test's to release (`page`), as the side
  # case does: the fake's unconditional page would hand the run a run
  # "held before" the words.
  def test_say_reads_the_bodys_model_and_approval_mode_and_answers_the_turn_and_run_it_waited_for
    page = Queue.new
    api = kernel_api(conversation_events: page)
    now = Time.utc(2026, 9, 17)
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil },
      clock: -> { page.empty? ? now : (now += Rho::Daemon::HostFollowers::MATERIALIZATION_POLL) },
      sleeper: ->(_seconds) { sleep 0.001 }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x")

    saying = Thread.new do
      request(daemon, :post, "/say", token: bearer(daemon),
        body: { public_id: "c-1", text: "next", delivery_mode: "queue", model: "openrouter/y", approval_mode: "ask" })
    end
    wait_for { api.conversation_inputs.any? }
    page << true
    response = saying.value

    assert_equal "200", response.code, response.body
    answer = JSON.parse(response.body)
    assert_equal({ "public_id" => "cin-1", "state" => "pending", "position" => { "cursor" => nil, "sequence" => 0 } }, answer.fetch("input"))
    assert_equal({ "public_id" => "t-1" }, answer.fetch("turn"), "the turn the kernel minted for these words")
    assert_equal({ "public_id" => "al-1" }, answer.fetch("run"))
    refute answer.key?("pending")
    input = api.conversation_inputs.fetch(0).fetch("input")
    assert_equal [{ "model" => "openrouter/y" }, "ask"], input.values_at("model", "approval_mode"),
      "the body's model ahead of the row's; the tightening as typed"
    assert_equal "openrouter/y", store.find("c-1").model, "what the turn rode is the row's from here"

    refused = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "c-1", text: "x", approval_mode: "telepathy" })
    assert_equal ["400", "malformed_body"], [refused.code, JSON.parse(refused.body).dig("error", "code")]
    assert_match(/approval_mode must be bypass, ask or rules/, JSON.parse(refused.body).dig("error", "message"))
    assert_equal 1, api.conversation_inputs.length, "refused before the wire"
  end

  # A WORD THAT QUEUES BEHIND A RUNNING TURN ANSWERS AT ONCE: the follower holds a turn in flight (`t-1` on
  # `al-1`, never settled on this feed), so these words open nothing until
  # it ends — `say` does not sit on the bound for them; it answers
  # `pending` with the kernel's own state word the moment the row is
  # accepted, and never the LAST turn's run as this one's. A STEER is the
  # same at-once answer under the kernel's `steering`: the daemon names
  # no turn or run off its pre-read of the running run. A RUN host's
  # `say` names neither and says no `pending` at all: its one turn is
  # already in flight, so there is nothing to wait for.
  def test_say_answers_pending_at_once_behind_a_running_turn_and_a_run_host_names_no_turn
    events = [turn_status_event(1, turn: "t-1", run_public_id: "al-1", kind: "direct_reply")]
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, conversation_events: events)
    daemon = member_ready(boot, api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1", model: "openrouter/x")

    daemon.context.member_plane(require_workspace: false) do |client, *|
      workspace = client.workspace("ws-1")
      host = conversation_host("c-1")
      daemon.host_followers.adopt_follower(host, host.context(workspace), {}, runs: workspace.runs)
    end
    wait_for { daemon.lineage.follower("c-1")&.event_position&.sequence == 1 }

    began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "c-1", text: "again", delivery_mode: "queue" })
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - began

    assert_equal "200", response.code, response.body
    answer = JSON.parse(response.body)
    assert_equal({ "public_id" => "cin-1", "state" => "pending", "position" => { "cursor" => "c1", "sequence" => 1 } }, answer.fetch("input"))
    assert answer.fetch("pending"), "no run was minted for these words, so nothing else is named: #{answer.inspect}"
    refute answer.key?("run"), "the LAST turn's run, answered as this one's"
    refute answer.key?("turn")
    refute answer.key?("blocked")
    assert_operator elapsed, :<, 5, "a word behind a running turn must not wait out the 30-second materialization bound"

    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "and this" })
    answer = JSON.parse(response.body)
    assert_equal "steering", answer.dig("input", "state"), "the kernel's word, relayed"
    assert answer.fetch("pending"), "a steer opens no turn of its own: #{answer.inspect}"
    refute answer.key?("turn"), "the running turn is the daemon's pre-read, never the steer's answer"
    refute answer.key?("run")

    store.remember(run_host("al-9"), workspace: "ws-1")
    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "al-9", text: "steer" })
    assert_equal "200", response.code, response.body
    answer = JSON.parse(response.body)
    assert_equal %w[default_runner input], answer.keys.sort, "a run's turn is in flight: no wait, no turn, no pending"
  end

  # A KERNEL BLOCK IS NOT A REFUSAL OF `say`: the
  # drain parks the input `blocked` with its reason word and the
  # conversation stands; the author answers 200 with the parked row —
  # `pending`, the reason under `blocked`, the row's state as the kernel
  # now holds it — the moment the block lands, never the bound, so
  # `rho inputs rm` can clear it. The `open` door keeps its 422: a first
  # turn that never opened is a refusal of the open.
  def test_a_queued_word_the_kernel_blocks_answers_the_parked_row_not_a_refusal
    start = Time.utc(2026, 9, 17)
    now = start
    events = [
      { "public_id" => "ev-1", "sequence" => 1, "cursor" => "c1", "type" => "input_blocked",
        "resource" => { "type" => "conversation", "public_id" => "c-1" },
        "occurred_at" => "2026-09-17T00:00:00Z",
        "payload" => { "input_public_id" => "cin-1", "queue_position" => 0, "blocked_reason" => "provider_disabled" } },
    ]
    api = NexusDoubles::FakeAgentApi.new(conversation_events: -> { api.conversation_inputs.empty? ? [] : events })
    daemon = member_ready(boot(clock: -> { now += Rho::Daemon::HostFollowers::MATERIALIZATION_POLL },
      sleeper: ->(_seconds) { sleep 0.001 }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x")

    response = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "c-1", text: "blocked?", delivery_mode: "queue" })

    assert_equal "200", response.code, response.body
    answer = JSON.parse(response.body)
    refute answer.key?("error"), answer.inspect
    assert answer.fetch("pending"), answer.inspect
    assert_equal "provider_disabled", answer.fetch("blocked"), "the kernel's reason word, verbatim"
    assert_equal({ "public_id" => "cin-1", "state" => "blocked", "blocked_reason" => "provider_disabled",
                   "position" => { "cursor" => nil, "sequence" => 0 } },
      answer.fetch("input"), "the parked row as the kernel now holds it")
    refute answer.key?("turn")
    refute answer.key?("run")
    assert_operator now - start, :<, Rho::Daemon::HostFollowers::MATERIALIZATION_WAIT, "the clock never reached the bound"
    refute_nil store.find("c-1"), "the conversation stands with the input parked"
  end

  # The kernel's `turn_status` for a conversation turn, with its kind
  # (the summarizer's turn is told apart by it).
  def turn_status_event(sequence, turn:, run_public_id:, kind:)
    { "public_id" => "ev-#{sequence}", "sequence" => sequence, "cursor" => "c#{sequence}", "type" => "turn_status",
      "resource" => { "type" => "conversation", "public_id" => "c-1" }, "occurred_at" => "2026-09-18T00:00:0#{sequence}Z",
      "payload" => { "status" => "running", "turn_public_id" => turn, "run_public_id" => run_public_id, "turn_kind" => kind } }
  end

  # A BETWEEN-TURN COMPACTION: the input's
  # arrival arms the kernel's summary, and the feed narrates the
  # `compaction_summary` turn FIRST — a new run past the bar that is not
  # the answer: `rho say` printed it as `run:`, and a caller following
  # it read the summarizer. The follower carries `turn_kind`, so the wait
  # reads past the summary's run and answers the person's turn — the
  # SECOND run — when it opens within the bound. The page is staged by
  # hand: the summary's item alone until the follower holds its run,
  # then the person's, so the wait is SEEN reading past the summary.
  def test_say_behind_a_between_turn_compaction_answers_the_persons_run_not_the_summarizers
    events = [turn_status_event(1, turn: "t-s", run_public_id: "al-s", kind: "compaction_summary"),
              input_materialized_event(2, input: "cin-1", turn: "t-2", variant: "v-2", run_id: "al-2"),
              turn_status_event(3, turn: "t-2", run_public_id: "al-2", kind: "direct_reply")]
    staged = Queue.new
    api = kernel_api(conversation_events: -> { events.first(staged.size == 2 ? 3 : staged.size) })
    now = Time.utc(2026, 9, 18)
    # A clock that never moves: the bound is not the property here.
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }, clock: -> { now },
      sleeper: ->(_seconds) { sleep 0.001 }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x")

    saying = Thread.new do
      request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "next", delivery_mode: "queue" })
    end
    wait_for { api.conversation_inputs.any? }
    staged << :summary
    wait_for { daemon.lineage.follower("c-1")&.snapshot&.run_public_id == "al-s" }
    assert_predicate saying, :alive?, "the summary's run is not the answer: the wait goes on"
    staged << :persons
    response = saying.value

    assert_equal "200", response.code, response.body
    answer = JSON.parse(response.body)
    assert_equal({ "public_id" => "t-2" }, answer.fetch("turn"), "the person's turn, never the summary's")
    assert_equal({ "public_id" => "al-2" }, answer.fetch("run"), "the SECOND run_public_id: the summarizer's is never `run_public_id:`")
    refute answer.key?("pending")
    refute answer.key?("compaction")
    wait_for { daemon.lineage.follower("c-1").snapshot.run_public_id == "al-2" }
    assert_equal %w[al-s al-2], daemon.lineage.follower("c-1").snapshot.run_public_ids, "the follower saw both"
  end

  # THE SUMMARY STILL IN FLIGHT AT THE BOUND: only its `turn_status`
  # arrived, so the honest answer is `pending` (a word
  # whose turn has not opened answers pending, never a guess) with the
  # summary's turn and run under `compaction`, for the verb to say what
  # runs first; nothing under `turn` or `run`.
  def test_say_answers_pending_with_the_compaction_when_only_the_summary_opened_within_the_bound
    summary = turn_status_event(1, turn: "t-s", run_public_id: "al-s", kind: "compaction_summary")
    page = Queue.new
    api = kernel_api(conversation_events: -> { page.empty? ? [] : [summary] })
    now = Time.utc(2026, 9, 18)
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil },
      clock: -> { page.empty? ? now : (now += Rho::Daemon::HostFollowers::MATERIALIZATION_POLL) },
      sleeper: ->(_seconds) { sleep 0.001 }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x")

    saying = Thread.new do
      request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "next", delivery_mode: "queue" })
    end
    wait_for { api.conversation_inputs.any? }
    page << true
    response = saying.value

    assert_equal "200", response.code, response.body
    answer = JSON.parse(response.body)
    assert_equal({ "public_id" => "cin-1", "state" => "pending", "position" => { "cursor" => nil, "sequence" => 0 } }, answer.fetch("input"))
    assert answer.fetch("pending"), answer.inspect
    assert_equal({ "turn" => { "public_id" => "t-s" }, "run" => { "public_id" => "al-s" } }, answer.fetch("compaction"),
      "the summary's ids, named as what they are")
    refute answer.key?("turn")
    refute answer.key?("run"), "the summarizer's run is never the turn's"
    refute answer.key?("blocked")
    assert_operator now - Time.utc(2026, 9, 18), :>=, Rho::Daemon::HostFollowers::MATERIALIZATION_WAIT, "the wait ran to the bound"
  end

  # THE MODEL OF A ROW THIS DAEMON ONLY ATTACHED: a
  # conversation another agent spawned rho into remembers no model, so
  # `say` reads rho's own `default_model` first, else THE ADDRESSED
  # TURN'S — the run projection's `turn.model`, the stated place the
  # kernel carries the initiator's model — and refuses only when the
  # wire carries none either. What it read is remembered on the row.
  def test_say_on_an_attached_row_falls_to_the_settings_default_then_the_turns_model_and_refuses_last
    turn = { "status" => "running", "public_id" => "t-1", "conversation_public_id" => "c-1",
             "model" => { "model" => "openrouter/from-turn", "reasoning_effort" => "low" } }
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE.merge("turn" => turn))
    daemon = member_ready(boot, api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-9")

    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "hi" })
    assert_equal "200", response.code, response.body
    assert_equal({ "model" => "openrouter/from-turn" }, api.conversation_inputs.fetch(0).dig("input", "model"),
      "no default_model: the addressed turn's model, read off the run projection")
    assert_equal "openrouter/from-turn", store.rows.fetch(0).model, "remembered, as an opened row's is"

    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE.merge("turn" => turn))
    preset = member_ready(boot(root: File.join(@root, "preset"),
      config: Rho::Config.from_hash({ "default_model" => "openrouter/own" })), api)
    preset_store = host_store(preset)
    preset_store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-9")
    response = request(preset, :post, "/say", token: bearer(preset), body: { public_id: "c-1", text: "hi" })
    assert_equal "200", response.code, response.body
    assert_equal({ "model" => "openrouter/own" }, api.conversation_inputs.fetch(0).dig("input", "model"),
      "rho's own default_model beats the turn's")

    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE.merge("turn" => turn.except("model")))
    bare = member_ready(boot(root: File.join(@root, "bare")), api)
    host_store(bare)
      .remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-9")
    response = request(bare, :post, "/say", token: bearer(bare), body: { public_id: "c-1", text: "hi" })
    assert_equal ["400", "malformed_body"], [response.code, JSON.parse(response.body).dig("error", "code")]
    assert_match(/model is required/, JSON.parse(response.body).dig("error", "message"))
    assert_empty api.conversation_inputs, "nothing posted: the kernel would only park it"
  end

  # THE MAINLINE'S MODEL, REMEMBERED AT TURN SETTLE: when the kernel moved
  # the turn's main line to the answerer's fallback (a refused round the
  # fallback re-ran; its continuation inherits it), the run projection's
  # `turn.model` — the mainline tail, the stated place — is where the turn
  # ended up, and the next `say` on the row rides it rather than sending
  # the declining model the same context again. A task member's switch
  # never moves `turn.model`, so it never moves the row; the kernel keeps
  # no routing state — this row is the caller's memory.
  def settled_turn_events
    NexusDoubles::FakeAgentApi::MATERIALIZED_EVENTS + [
      { "public_id" => "ev-3", "sequence" => 3, "cursor" => "c3", "type" => "turn_status",
        "resource" => { "type" => "conversation", "public_id" => "c-1" },
        "occurred_at" => "2026-09-06T00:00:01Z",
        "payload" => { "status" => "completed", "turn_public_id" => "t-1", "run_public_id" => "al-1",
                       "run_status" => "completed" } },
    ]
  end

  def mainline_trace(turn_model, tasks: NexusDoubles::RUNNING_TRACE.fetch("tasks"))
    NexusDoubles::RUNNING_TRACE.merge("status" => "completed", "tasks" => tasks,
      "turn" => { "status" => "completed", "public_id" => "t-1", "conversation_public_id" => "c-1",
                  "model" => { "model" => turn_model, "reasoning_effort" => nil } })
  end

  def test_a_mainline_switch_moves_the_remembered_model_at_turn_settle
    api = NexusDoubles::FakeAgentApi.new(trace: mainline_trace("dev/fallback"),
      conversation_events: -> { api.conversation_inputs.empty? ? [] : settled_turn_events })
    daemon = member_ready(boot, api)

    code, answer = open(daemon, { "prompt" => "fetch and merge", "model" => "dev/primary" })
    assert_equal "201", code, answer.inspect
    wait_for { store.find("c-1")&.model == "dev/fallback" }

    request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "and now the tests" })
    assert_equal({ "model" => "dev/fallback" }, api.conversation_inputs.last.dig("input", "model"),
      "the next turn rides where the last one ended, not the model that declined it")
  end

  def test_a_member_switch_leaves_the_remembered_model_where_the_mainline_is
    member = { "key" => "r1t0-model-1", "kind" => "model_task", "lifetime" => "turn", "wake" => "auto",
               "status" => "completed", "on_failure" => "absorb", "visibility" => "visible",
               "model" => { "model" => "dev/fallback", "reasoning_effort" => nil },
               "result" => { "model_change" => { "from" => "dev/primary", "reason" => "model_refused" } },
               "created_at" => "2026-09-05T00:00:00Z" }
    api = NexusDoubles::FakeAgentApi.new(trace: mainline_trace("dev/primary", tasks: [member]),
      conversation_events: -> { api.conversation_inputs.empty? ? [] : settled_turn_events })
    daemon = member_ready(boot, api)

    open(daemon, { "prompt" => "fetch and merge", "model" => "dev/primary" })
    wait_for { api.requests.count { |path, _| path.end_with?("/runs/al-1") } >= 1 }
    request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "and now the tests" })
    assert_equal({ "model" => "dev/primary" }, api.conversation_inputs.last.dig("input", "model"),
      "a member's switch is that member's; the main line stays where the mainline is")
    assert_equal "dev/primary", store.find("c-1").model
  end

  # A local conversation uses the full declaration and renders its lead on say.
  def test_say_keeps_the_model_and_renders_the_local_turn_surface
    api = kernel_api
    daemon = member_ready(boot(config: catalog_config), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1", model: "openrouter/x")

    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "more" })
    assert_equal "200", response.code, response.body
    input = api.conversation_inputs.fetch(0).fetch("input")
    refute input.key?("tool_names"), "no foreign runner or editor tools require narrowing"
    assert_equal({ "kind" => "direct_reply", "text" => "more", "delivery_mode" => "steer",
                   "model" => { "model" => "openrouter/x" } }, input.except("inline"))
    assert_equal %w[developer lead], [input.dig("inline", 0, "role"), input.dig("inline", 0, "position")]
  end

  # An id the store does not know is refused rather than guessed at: the
  # host decides the kind, and a host nobody here follows has none. STOP
  # IS THE EXCEPTION: a conversation this daemon never
  # followed — a child the model spawned — is canceled through the
  # kernel's own door, the cascade the kernel's, and the answer says it
  # was not followed here; the kernel's `not_found` is what an unknown id
  # gets. A branch cancel still needs the followed row (the backing run).
  def test_say_refuses_and_stop_relays_an_id_this_daemon_does_not_follow
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)

    said = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "al-nope", text: "hi" })
    assert_equal "404", said.code
    assert_equal "host_not_followed", JSON.parse(said.body).dig("error", "code")
    assert_match(/attach/, JSON.parse(said.body).dig("error", "message"))

    stopped = request(daemon, :post, "/stop", token: bearer(daemon), body: { public_id: "c-child", host_type: "conversation" })
    assert_equal "200", stopped.code, stopped.body
    assert_equal({ "host_type" => "conversation", "public_id" => "c-child", "status" => "canceling", "followed" => false },
      JSON.parse(stopped.body).fetch("stopped"))
    assert(api.requests.any? { |path, _| path.end_with?("/conversations/c-child/cancellation") },
      "an unfollowed conversation is canceled through the kernel")

    branch = request(daemon, :post, "/stop", token: bearer(daemon), body: { public_id: "c-child", task_key: "r1t0" })
    assert_equal "404", branch.code
    assert_equal "host_not_followed", JSON.parse(branch.body).dig("error", "code")
  end

  def test_stop_ends_the_followed_host_through_its_own_verb_and_names_it
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)
    store.remember(run_host("al-1"), workspace: "ws-1")
    store.remember(conversation_host("c-1"), workspace: "ws-1", run_public_id: "al-2")

    response = request(daemon, :post, "/stop", token: bearer(daemon), body: { public_id: "al-1", force: false })
    assert_equal "200", response.code, response.body
    assert_equal({ "host_type" => "run", "public_id" => "al-1", "status" => "canceling" },
      JSON.parse(response.body).fetch("stopped"))
    assert(api.requests.any? { |path, _| path.end_with?("/runs/al-1/stop") })

    canceled = request(daemon, :post, "/stop", token: bearer(daemon), body: { public_id: "al-2" })
    assert_equal({ "host_type" => "conversation", "public_id" => "c-1", "status" => "canceling" },
      JSON.parse(canceled.body).fetch("stopped"))
    assert(api.requests.any? { |path, _| path.end_with?("/conversations/c-1/cancellation") },
      "a conversation's stop is its cancellation")
    refute(api.requests.any? { |path, _| path.end_with?("/runs/al-2/stop") })
  end

  # THE THIRD HOST-TYPED VERB: `/compact` reaches
  # each host's own door. A conversation compacts through its own
  # compaction route — the kernel picks the round, so a key is refused —
  # and answers the turn the repair rides plus, mid-turn, the round and
  # the summarizer; a run compacts the ONE round the key names, and
  # without a key refuses rather than guessing from the repair chooser.
  def test_compact_reaches_the_conversation_door_and_the_runs_named_round
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE,
      compaction: { "turn" => { "public_id" => "t-1", "position" => 3, "kind" => "direct_reply", "status" => "running" },
                    "task" => { "key" => "r7", "status" => "waiting" }, "summary_task_key" => "k1" })
    daemon = member_ready(boot, api)
    store.remember(run_host("al-1"), workspace: "ws-1")
    store.remember(conversation_host("c-1"), workspace: "ws-1", run_public_id: "al-2")

    response = request(daemon, :post, "/compact", token: bearer(daemon), body: { public_id: "al-2" })
    assert_equal "200", response.code, response.body
    assert_equal({ "host_type" => "conversation", "public_id" => "c-1", "turn" => "t-1", "turn_kind" => "direct_reply",
                   "task_key" => "r7", "summary_task_key" => "k1" },
      JSON.parse(response.body).fetch("compacted"))
    assert(api.requests.any? { |path, _| path.end_with?("/conversations/c-1/compaction") })
    assert_equal([{ "compaction" => {} }], api.compactions, "unnamed, the model is the conversation's own")
    refute(api.requests.any? { |path, _| path.include?("/runs/al-2/tasks") },
      "a conversation is compacted at its own door, never on its backing run's task")

    keyed = request(daemon, :post, "/compact", token: bearer(daemon), body: { public_id: "c-1", task_key: "r7" })
    assert_equal "400", keyed.code, "a conversation picks its own round"

    compacted = request(daemon, :post, "/compact", token: bearer(daemon), body: { public_id: "al-1", task_key: "work" })
    assert_equal "200", compacted.code, compacted.body
    assert_equal({ "host_type" => "run", "public_id" => "al-1", "task_key" => "work", "summary_task_key" => "k1" },
      JSON.parse(compacted.body).fetch("compacted"))
    assert(api.requests.any? { |path, _| path.end_with?("/runs/al-1/tasks/work/compact") })

    bare = request(daemon, :post, "/compact", token: bearer(daemon), body: { public_id: "al-1" })
    assert_equal "400", bare.code, "a run names the round: nothing says which of its queued rounds a person meant"
    assert_equal "404", request(daemon, :post, "/compact", token: bearer(daemon), body: { public_id: "al-nope" }).code
  end

  # A TASK KEY CANCELS ONE BRANCH on the run the id names: a conversation's current backing run through the store
  # row, a run's own; the host is not stopped.
  def test_stop_with_a_task_key_cancels_the_branch_on_the_backing_run
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)
    store.remember(run_host("al-1"), workspace: "ws-1")
    store.remember(conversation_host("c-1"), workspace: "ws-1", run_public_id: "al-2")

    response = request(daemon, :post, "/stop", token: bearer(daemon), body: { public_id: "c-1", task_key: "r3t1" })
    assert_equal "200", response.code, response.body
    assert_equal({ "host_type" => "task", "public_id" => "r3t1", "status" => "canceled", "run_public_id" => "al-2" },
      JSON.parse(response.body).fetch("stopped"))
    assert(api.requests.any? { |path, _| path.end_with?("/runs/al-2/tasks/r3t1/cancel") },
      "a conversation id names its backing run")
    refute(api.requests.any? { |path, _| path.end_with?("/cancellation") }, "the turn runs on")

    own = request(daemon, :post, "/stop", token: bearer(daemon), body: { public_id: "al-1", task_key: "r3t1" })
    assert_equal "al-1", JSON.parse(own.body).dig("stopped", "run_public_id")
    assert(api.requests.any? { |path, _| path.end_with?("/runs/al-1/tasks/r3t1/cancel") })
    refute(api.requests.any? { |path, _| path.end_with?("/runs/al-1/stop") })
  end

  # THE ONE RESOLUTION RULE for a run id, through the facade a
  # follower verb uses: a row rho placed answers first, else the run's
  # own turn block — its conversation when it is run-backed.
  def test_a_run_id_resolves_to_the_host_that_follows_it
    trace = NexusDoubles::RUNNING_TRACE.merge(
      "turn" => { "status" => "running", "public_id" => "t-9", "conversation_public_id" => "c-9" }
    )
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(trace: trace))
    store.remember(conversation_host("c-1"), workspace: "ws-1", run_public_id: "al-1")
    runs = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1").runs

    assert_equal conversation_host("c-1"), daemon.context.host_of("al-1", runs)
    assert_equal conversation_host("c-9"), daemon.context.host_of("al-9", runs)
  end

  # A SECOND TURN moves the row's run, and the first turn's run id must
  # still name the conversation for `rho follow` and `rho subscribe`. The
  # store row carries only the current run, while the follower saw every
  # run — `runs`, the rule `rho watch`
  # reads rows by — and the one lookup every follower verb uses reads
  # that history too.
  def test_an_earlier_turns_run_id_still_names_the_conversation_it_backed
    second_turn = NexusDoubles::FakeAgentApi::MATERIALIZED_EVENTS + [
      { "public_id" => "ev-3", "sequence" => 3, "cursor" => "c3", "type" => "turn_status",
        "resource" => { "type" => "conversation", "public_id" => "c-1" },
        "occurred_at" => "2026-09-06T00:00:01Z",
        "payload" => { "status" => "running", "turn_public_id" => "t-2", "run_public_id" => "al-2" } },
    ]
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, conversation_events: -> { api.conversation_inputs.empty? ? [] : second_turn })
    daemon = member_ready(boot, api)
    open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "idempotency_key" => "k-a" })
    wait_for { followed(daemon).fetch(0).fetch("run_public_ids") == %w[al-1 al-2] }
    assert_equal "al-2", store.find("c-1").run_public_id, "the row carries the current run only"

    assert_equal "c-1", daemon.host_followers.followed("al-1")&.public_id, "the earlier turn's run names its conversation"
    assert_equal "c-1", daemon.host_followers.followed("al-2")&.public_id
    assert_nil daemon.host_followers.followed("al-nope")

    subscribed = request(daemon, :post, "/followers/subscribe", token: bearer(daemon), body: { "public_id" => "al-1" })
    assert_equal "200", subscribed.code, subscribed.body
    assert_equal "c-1", JSON.parse(subscribed.body).dig("follower", "public_id")

    # A store that cannot be read costs the row, never the follower: the
    # history is the run's own.
    File.write(daemon.home.host_cache_path(daemon.lineage.identity.user_public_id), "{not json")
    assert_equal "c-1", daemon.host_followers.followed("al-1")&.public_id
  end
end
