require "support/daemon_loop_helpers"

class DaemonLoopsTest < Minitest::Test
  include RhoTest::DaemonLoopHelpers

  # ---- side conversations: rho's bookkeeping over the kernel's side fork ----

  def side(daemon, body)
    response = request(daemon, :post, "/side", token: bearer(daemon), body: body)
    [response.code, JSON.parse(response.body)]
  end

  def side_note(public_id) = store.find(public_id).notes.fetch(Rho::Daemon::Loops::SIDE_NOTE)

  # `POST /side`: the parent is the newest live conversation
  # this daemon follows; the kernel's side fork is asked ONCE per parent —
  # rho's one-open rule, the kernel knows none — and the side is followed
  # and remembered with the parent's model, tier and runner under its own
  # note. With `text`, one `direct_reply` goes out on the side: `queue`,
  # the parent's model, the posture's tools and ONE inline entry — the
  # side sentence as a USER-role TAIL, behind the inherited history, so
  # the prefix the parent shares stays whole. `none` (`rho
  # btw`) DECLARES THE PARENT'S WHOLE SET — the provider's prefix cache
  # needs the parent's tool block (0 vs 5,632 cached tokens) — with
  # the turn tightened to `ask`, so no call runs: every park is denied by
  # the daemon (the next test). A second call reuses the open side;
  # `read` narrows to rho's read-only subset and never a mutating tool.
  def test_side_forks_the_newest_conversation_once_and_reuses_the_open_side
    # The page is the test's to release (`page`), once the question went
    # out: a side just forked has no turn to replay, and the fake's
    # unconditional page raced the route's `before` read — won by whichever
    # side paid the runner root's first `tool_env` build (the checkpoint
    # store's open). And no real time: the follower is the REST one (no
    # socket — a test daemon's socket to nexus.example never opens, and
    # the feed's transient budget on it timed the second `/events` read
    # at 29.9 s, a hair under the 30 s bound; beside two worlds it crossed
    # it: the `KeyError "loop"`), its poll and the wait's are one yield
    # each, and the bound is the injected clock's, which stands still
    # until the page exists — a starved machine cannot spend it.
    page = Queue.new
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: page)
    now = Time.utc(2026, 9, 6)
    daemon = member_ready(boot(config: tiered, realtime_factory: ->(*) { nil },
      clock: -> { page.empty? ? now : (now += Rho::Daemon::Loops::MATERIALIZATION_POLL) },
      sleeper: ->(_seconds) { sleep 0.001 }), api)
    store.remember(conversation_host("c-0"), workspace: "ws-1", model: "openrouter/old")
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", loop: "al-1",
      model: "openrouter/x", compose: false)

    asking = Thread.new { side(daemon, { "tools" => "none", "text" => "what are you doing?" }) }
    wait_for { api.conversation_inputs.any? }
    page << true
    code, answer = asking.value

    assert_equal "201", code, answer.inspect
    assert_equal({ "public_id" => "c-1-side" }, answer.fetch("side"))
    assert_equal({ "public_id" => "c-1" }, answer.fetch("parent"), "the newest live conversation, never c-0")
    assert_equal({ "public_id" => "al-1" }, answer["loop"],
      "the turn materialized, as `do` waits for it — the route answered #{answer.inspect}")
    assert_equal [["c-1", { "fork" => { "side" => true } }]], api.forks, "the kernel's side fork, no turn named"
    input = api.conversation_inputs.fetch(0).fetch("input")
    assert_equal ["direct_reply", "what are you doing?", "queue", { "model" => "openrouter/x" }, "ask"],
      input.values_at("kind", "text", "delivery_mode", "model", "approval_mode")
    request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "carry on" })
    parent_input = api.conversation_inputs.fetch(1).fetch("input")
    assert_equal parent_input["tool_names"], input["tool_names"],
      "the btw turn declares the PARENT's set — what a `say` on the parent sends — never `[]`"
    refute_equal [], input["tool_names"]
    refute_includes input["tool_names"], "compose", "the own-answerer side keeps the parent's tier"
    refute parent_input.key?("approval_mode"), "the tightening is the side's alone"
    tail, *rest = input.fetch("inline")
    assert_empty rest, "ONE inline entry"
    assert_equal %w[user tail], [tail.fetch("role"), tail.fetch("position")]
    assert_equal Rho::Daemon::Loops::SIDE_LEADS.fetch("none"), tail.fetch("text")
    assert(api.requests.any? { |path, _| path.end_with?("/conversations/c-1-side/inputs") }, "on the SIDE's door")
    row = store.find("c-1-side")
    assert_equal ["conversation", "openrouter/x", false], [row.host_type, row.model, row.compose]
    assert_nil row.answerer, "rho's own answerer keeps the ordinary tier path"
    assert_equal "c-1", side_note("c-1-side").fetch("parent")
    assert_equal "none", side_note("c-1-side").fetch("tools")
    refute_nil side_note("c-1-side")["last_turn_at"]
    assert_includes daemon.lineage.runs.map(&:public_id), "c-1-side", "the side is followed"

    code, answer = side(daemon, { "tools" => "read" })
    assert_equal "200", code, answer.inspect
    assert_equal({ "public_id" => "c-1-side" }, answer.fetch("side"))
    assert answer.fetch("reused")
    assert_equal 1, api.forks.length, "the open side is reused, never forked again"
    assert_equal 2, api.conversation_inputs.length, "no text, no input"
    assert_equal "read", side_note("c-1-side").fetch("tools"), "the posture moves with the last open"

    code, answer = side(daemon, { "parent_public_id" => "c-1-side", "tools" => "none" })
    assert_equal "200", code, answer.inspect
    assert_equal "c-1-side", answer.dig("side", "public_id"), "the side's own id names it too"
    assert_equal "c-1", answer.dig("parent", "public_id")

    assert_equal "400", side(daemon, { "tools" => "write" }).first
    assert_equal "404", side(daemon, { "parent_public_id" => "c-nope", "tools" => "none" }).first
  end

  # A SECOND QUESTION ON THE REUSED SIDE waits for ITS OWN loop. The side's
  # follower still holds the first question's settled loop (`al-1`) until
  # the next turn's first item resets it, and the wait `do` taught this
  # route answered the first loop it saw — so `rho btw` joined the settled
  # turn, printed the FIRST answer again and ended (the e2e's second btw
  # echoed the first). With no second turn on the feed the honest answer
  # is `pending`, never `al-1`; the clock is stepped so the bound elapses.
  def test_a_second_question_on_the_reused_side_waits_for_its_own_loop_and_never_answers_the_last_ones
    api = kernel_api(user_public_id: IDENTITY.user_public_id)
    now = Time.utc(2026, 9, 12, 12)
    daemon = member_ready(boot(config: tiered, realtime_factory: ->(*) { nil }, clock: -> { now += 60 }, sleeper: ->(_) { }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x", compose: false)

    code, = side(daemon, { "tools" => "none", "text" => "what are you doing?" })
    assert_equal "201", code
    wait_for { daemon.loops.followed("al-1")&.public_id == "c-1-side" }

    code, answer = side(daemon, { "tools" => "none", "text" => "try a tool" })

    assert_equal "200", code, answer.inspect
    assert answer.fetch("reused")
    assert_equal 2, api.conversation_inputs.length, "the second question went out on the side"
    refute_equal({ "public_id" => "al-1" }, answer["loop"], "the LAST question's loop, answered as this one's")
    assert answer.fetch("pending"), "no loop was minted for this question, so nothing else is named: #{answer.inspect}"
  end

  # THE AUTO-DENY: a park the btw turn raises —
  # `attention_required{approval_required}` on the side's feed — is denied
  # through the kernel's door with ONE model-facing sentence, the only new
  # bytes the model reads (Claude Code's own shape: tools present, blocked
  # by permission). A `read` side's park is a person's to decide.
  def test_a_park_on_a_btw_side_is_denied_with_the_side_sentence_and_a_read_sides_is_not
    running = { "public_id" => "ev-2", "sequence" => 2, "cursor" => "c2", "type" => "turn_status",
                "resource" => { "type" => "conversation", "public_id" => "c-1-side" },
                "occurred_at" => "2026-09-06T00:00:00Z",
                "payload" => { "status" => "running", "turn_public_id" => "t-1", "agent_loop_public_id" => "al-1" } }
    parked = running.merge("public_id" => "ev-3", "sequence" => 3, "cursor" => "c3", "type" => "attention_required",
      "payload" => { "reason" => "approval_required", "blocked_task_keys" => %w[r1t0 r1t1],
        "turn_public_id" => "t-1", "agent_loop_public_id" => "al-1" })
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, trace: NexusDoubles::RUNNING_TRACE, tools: NexusDoubles::KERNEL_CATALOG,
      conversation_events: -> {
        count = api.conversation_inputs.length
        resource = { "type" => "conversation", "public_id" => "c-#{count}-side" }
        count.zero? ? [] : [input_materialized_event(1, input: "cin-#{count}", turn: "t-1", conversation: "c-#{count}-side"),
          running.merge("resource" => resource), parked.merge("resource" => resource)]
      })
    daemon = member_ready(boot(config: tiered, realtime_factory: ->(*) { nil }, sleeper: ->(_) { }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x", compose: false)
    store.remember(conversation_host("c-2"), workspace: "ws-1", model: "openrouter/x", compose: false)

    code, = side(daemon, { "parent_public_id" => "c-1", "tools" => "none", "text" => "what are you doing?" })
    assert_equal "201", code

    denials = await_adjudications(api, 2)
    assert_equal [["deny", "r1t0", { "reason" => Rho::Daemon::Loops::SIDE_DENIAL }],
                  ["deny", "r1t1", { "reason" => Rho::Daemon::Loops::SIDE_DENIAL }]], denials
    assert(api.requests.any? { |path, _| path.end_with?("/agent_loops/al-1/tasks/r1t0/deny") }, "on the side's loop")
    assert_match(/event=side\.park_denied/, File.read(daemon.home.log_path, encoding: Encoding::UTF_8))

    code, = side(daemon, { "parent_public_id" => "c-2", "tools" => "read", "text" => "and the tests?" })
    assert_equal "201", code
    sleep 0.2
    assert_equal 2, api.adjudications.length, "a read side's park waits for a person"
  end

  def test_an_active_side_recovers_its_policy_after_follower_cache_eviction
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    host = conversation_host("c-active-side")
    note = { "parent" => "c-parent", "tools" => "none", "last_turn_at" => Time.now.iso8601 }
    store.remember(host, workspace: "ws-1", model: "dev/side", notes: { "rho.side" => note })
    workspace = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1")
    run = nil
    capturing_spawns(daemon) do
      run = daemon.loops.adopt_run(host, host.context(workspace), {}, loops: workspace.agent_loops)
    end
    Rho::HostStore::MAX_ROWS.times { |index| store.remember(loop_host("cached-#{index}"), workspace: "ws-1") }
    assert_nil store.find(host.public_id)
    attention = Rho::HostRun::Attention.new(reason: "approval_required", blocked_task_keys: ["r1t2"])

    daemon.loops.follow_attention(run, attention, workspace.agent_loops, "al-side", hosted: host.context(workspace))

    assert_equal [["deny", "r1t2", { "reason" => Rho::Daemon::Loops::SIDE_DENIAL }]], api.adjudications
    assert_equal "none", store.find(host.public_id).notes.dig("rho.side", "tools")
  end

  def test_an_evicted_sides_failed_policy_read_is_retried_before_its_next_attention
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    host = conversation_host("c-active-side")
    store.remember(host, workspace: "ws-1", notes: { "rho.side" => { "parent" => "c-parent", "tools" => "none" } })
    workspace = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1")
    hosted = host.context(workspace)
    run = nil
    capturing_spawns(daemon) { run = daemon.loops.adopt_run(host, hosted, {}, loops: workspace.agent_loops) }
    Rho::HostStore::MAX_ROWS.times { |index| store.remember(loop_host("cached-#{index}"), workspace: "ws-1") }
    original_call = api.method(:call)
    api.define_singleton_method(:call) do |path, **options|
      if path.include?("/store_entries") && options.fetch(:method, :get) == :get
        CybrosAgent::Response.new(status: 503, headers: {}, body: nil)
      else
        original_call.call(path, **options)
      end
    end
    attention = Rho::HostRun::Attention.new(reason: "approval_required", blocked_task_keys: ["r1t2"])

    assert_raises(CybrosAgent::Api::Error) do
      daemon.loops.follow_attention(run, attention, workspace.agent_loops, "al-side", hosted: hosted)
    end
    assert_nil store.find(host.public_id), "a failed read must not cache an unverified empty policy"
    assert_empty api.adjudications
    api.define_singleton_method(:call, original_call)

    daemon.loops.follow_attention(run, attention, workspace.agent_loops, "al-side", hosted: hosted)

    assert_equal [["deny", "r1t2", { "reason" => Rho::Daemon::Loops::SIDE_DENIAL }]], api.adjudications
    assert_equal "none", store.find(host.public_id).notes.dig("rho.side", "tools")
  end

  def test_a_previous_side_turns_background_park_is_denied_on_its_own_loop
    source = { "turn_public_id" => "old-turn", "variant_public_id" => "old-variant", "agent_loop_public_id" => "old-loop" }
    next_source = { "turn_public_id" => "next-turn", "variant_public_id" => "next-variant", "agent_loop_public_id" => "next-loop" }
    payloads = [
      ["turn_status", source.merge("status" => "running", "loop_status" => "running")],
      ["turn_status", source.merge("status" => "completed", "loop_status" => "running")],
      ["turn_status", next_source.merge("status" => "running", "loop_status" => "running")],
      ["attention_required", source.merge("reason" => "approval_required", "blocked_task_keys" => ["r1t0"])],
    ]
    events = payloads.each_with_index.map do |(type, payload), index|
      sequence = index + 2
      { "public_id" => "event-#{sequence}", "sequence" => sequence, "cursor" => "cursor-#{sequence}", "type" => type,
        "resource" => { "type" => "conversation", "public_id" => "c-1-side" }, "occurred_at" => "2026-09-20T00:00:00Z",
        "payload" => payload }
    end
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, trace: NexusDoubles::RUNNING_TRACE, tools: NexusDoubles::KERNEL_CATALOG,
      conversation_events: -> {
        api.conversation_inputs.empty? ? [] :
          [input_materialized_event(1, input: "cin-1", turn: "old-turn", conversation: "c-1-side"), *events]
      })
    daemon = member_ready(boot(config: tiered, realtime_factory: ->(*) { nil }, sleeper: ->(_) { }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x", compose: false)

    code, = side(daemon, { "tools" => "none", "text" => "a side question" })
    assert_equal "201", code
    await_adjudications(api, 1)

    paths = api.requests.map(&:first).select { |path| path.end_with?("/deny") }
    assert_equal ["/agent_api/v1/workspaces/ws-1/agent_loops/old-loop/tasks/r1t0/deny"], paths
    run = daemon.loops.followed("next-loop")
    assert_equal "next-loop", run.snapshot.loop
    assert_nil run.snapshot.attention

    attention = Rho::HostRun::Attention.new(reason: "approval_required", blocked_task_keys: ["r1t1"])
    workspace = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1")
    assert_nil daemon.loops.follow_attention(run, attention, workspace, nil, hosted: nil)
    assert_equal paths, api.requests.map(&:first).select { |path| path.end_with?("/deny") },
      "an event without a source cannot borrow the current loop"
  end

  def await_adjudications(api, count, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until api.adjudications.length >= count
      raise "only #{api.adjudications.inspect} after #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
    api.adjudications
  end

  # `say` on a side row applies the posture's subset and the tail on
  # every turn, and never a developer lead — where a plain conversation
  # carries one on every say.
  def test_say_on_a_side_applies_the_read_subset_and_the_tail_and_never_a_lead
    api = kernel_api(user_public_id: IDENTITY.user_public_id)
    now = Time.utc(2026, 9, 10, 12)
    daemon = member_ready(boot(config: tiered, clock: -> { now += 60 }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x", compose: false)
    side(daemon, { "tools" => "read" })
    before = side_note("c-1-side").fetch("last_turn_at")

    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1-side", text: "and the tests?" })

    assert_equal "200", response.code, response.body
    input = api.conversation_inputs.fetch(0).fetch("input")
    names = input.fetch("tool_names")
    assert_includes names, "read"
    assert_includes names, "grep"
    assert_includes names, "ls"
    refute_includes names, "bash"
    refute_includes names, "write"
    refute_includes names, "edit"
    refute_includes names, "task", "no branch from a side"
    refute_includes names, "compose"
    assert_equal names, Rho::Daemon::Loops::READ_ONLY_SUBSET & names, "rho's list, in rho's order"
    assert_equal [{ "role" => "user", "position" => "tail", "text" => Rho::Daemon::Loops::SIDE_LEADS.fetch("read") }],
      input.fetch("inline"), "the tail alone: no lead on a side, where a plain turn carries one every say"
    assert_equal "steer", input.fetch("delivery_mode")
    refute_equal before, side_note("c-1-side").fetch("last_turn_at"), "a turn keeps the side alive"
  end

  def test_a_side_uses_the_selected_model_on_the_first_submission_and_its_replay
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(config: tiered, realtime_factory: ->(*) { nil }), api)

    %w[none read].each_with_index do |tools, index|
      parent_id = "c-#{index + 1}"
      store.remember(conversation_host(parent_id), workspace: "ws-1", model: "openrouter/old", compose: false)
      code, opened = side(daemon, { "parent_public_id" => parent_id, "tools" => tools })
      assert_equal "201", code, opened.inspect
      side_id = opened.fetch("side").fetch("public_id")
      body = { public_id: side_id, text: "another question", delivery_mode: "queue", model: "openrouter/new",
               idempotency_key: "side-question-#{index}", wait: false }
      before = api.conversation_inputs.length

      2.times do
        response = request(daemon, :post, "/say", token: bearer(daemon), body: body)
        assert_equal "200", response.code, response.body
      end

      first, replay = api.conversation_inputs.drop(before).map { |entry| entry.fetch("input") }
      assert_equal({ "model" => "openrouter/new" }, first.fetch("model"), "#{tools}: selected model applies immediately")
      assert_equal first, replay, "remembering the chosen model cannot change the replayed input"
      assert_equal "openrouter/new", store.find(side_id).model
      assert_equal "openrouter/old", store.find(parent_id).model, "the side does not change its parent's model"
    end
  end

  def test_a_side_refuses_tool_expansion_and_approval_overrides
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(config: tiered, realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x")
    code, opened = side(daemon, { "tools" => "read" })
    assert_equal "201", code, opened.inspect
    side_id = opened.fetch("side").fetch("public_id")

    [{ tool_names: ["bash"] }, { approval_mode: "rules" }].each do |fields|
      response = request(daemon, :post, "/say", token: bearer(daemon),
        body: { public_id: side_id, text: "Tighter", wait: false }.merge(fields))
      assert_equal "400", response.code, response.body
      assert_match(/posture/, JSON.parse(response.body).dig("error", "message"))
    end
    assert_empty api.conversation_inputs
  end

  def test_a_side_can_further_narrow_its_tools_without_changing_its_posture
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(config: tiered, realtime_factory: ->(*) { nil }), api)

    %w[none read].each_with_index do |tools, index|
      parent_id = "c-#{index + 1}"
      store.remember(conversation_host(parent_id), workspace: "ws-1", model: "openrouter/x", compose: false)
      code, opened = side(daemon, { "parent_public_id" => parent_id, "tools" => tools })
      assert_equal "201", code, opened.inspect
      side_id = opened.fetch("side").fetch("public_id")
      [[], ["read"]].each do |names|
        before = api.conversation_inputs.length
        body = { public_id: side_id, text: "A narrower question", delivery_mode: "queue",
                 tool_names: names, idempotency_key: "#{tools}-#{names.join}", wait: false }
        2.times do
          response = request(daemon, :post, "/say", token: bearer(daemon), body: body)
          assert_equal "200", response.code, response.body
        end
        first, replay = api.conversation_inputs.drop(before).map { |entry| entry.fetch("input") }
        assert_equal names, first.fetch("tool_names")
        assert_equal first, replay, "the explicitly narrowed input survives a replay"
        if tools == "none"
          assert_equal "ask", first.fetch("approval_mode")
        else
          refute first.key?("approval_mode")
        end
        assert_equal [Rho::Daemon::Loops::SIDE_LEADS.fetch(tools)], first.fetch("inline").map { |entry| entry.fetch("text") }
      end
      assert_equal tools, side_note(side_id).fetch("tools"), "input narrowing does not rewrite the side's posture"
    end
  end

  def test_a_side_refuses_a_malformed_tool_subset_before_submitting_input
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(config: tiered, realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x")
    side(daemon, { "tools" => "read" })

    response = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "c-1-side", text: "Malformed", tool_names: "read", wait: false })

    assert_equal "400", response.code, response.body
    assert_match(/tool_names must be a list/, JSON.parse(response.body).dig("error", "message"))
    assert_empty api.conversation_inputs
  end

  def test_a_foreign_btw_side_uses_the_forks_answerer_without_sending_the_personal_tool_subset
    child = { "public_id" => "c-1-side", "answering_user_public_id" => "fork-answerer", "side" => true,
              "parent" => { "public_id" => "c-1" }, "context_revision" => 0,
              "created_at" => "2026-09-30T00:00:00Z", "updated_at" => "2026-09-30T00:00:00Z",
              "input_queue" => { "limit" => 16, "held" => 0 }, "access" => { "default" => "full", "entries" => [] } }
    forked = CybrosAgent::Response.new(status: 201, headers: {},
      body: { "conversation" => child, "world" => { "status" => "untouched" } })
    api = kernel_api(user_public_id: IDENTITY.user_public_id, fork: forked, conversation_events: [])
    now = Time.utc(2026, 9, 30)
    daemon = member_ready(boot(config: tiered, realtime_factory: ->(*) { nil },
      clock: -> { now += 60 }, sleeper: ->(_) { }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x", compose: false,
      answerer: "parent-answerer")

    code, answer = side(daemon, { "parent_public_id" => "c-1", "tools" => "none", "text" => "a side question" })

    assert_equal "201", code, answer.inspect
    assert_equal "fork-answerer", store.find("c-1-side").answerer,
      "the kernel selects the fork-point answerer, which can differ from the parent's default"
    assert_equal "parent-answerer", store.find("c-1").answerer
    body = { public_id: "c-1-side", text: "another question", delivery_mode: "queue",
             idempotency_key: "foreign-side-question", wait: false }
    2.times do
      response = request(daemon, :post, "/say", token: bearer(daemon), body: body)
      assert_equal "200", response.code, response.body
    end

    inputs = api.conversation_inputs.map { |entry| entry.fetch("input") }
    assert_equal 3, inputs.length
    inputs.each do |input|
      refute input.key?("tool_names"), "the actual answerer's declaration owns the whole set, including on a replay"
      assert_equal "ask", input.fetch("approval_mode"), "the no-tool side still holds every call for auto-denial"
      assert_equal [{ "role" => "user", "position" => "tail", "text" => Rho::Daemon::Loops::SIDE_LEADS.fetch("none") }],
        input.fetch("inline")
    end
    assert_equal inputs[1], inputs[2], "remembered foreignness preserves the replayed input"
  end

  # THE IDLE SWEEP (rho's 24 h, never the kernel's): a side whose last
  # turn is older than the TTL is deleted through the kernel's door —
  # tombstone and reap at once — its follower ended and its row
  # forgotten; a younger one stands, and so does every plain row.
  def test_sweep_sides_deletes_a_side_idle_past_the_ttl_and_keeps_the_rest
    now = Time.utc(2026, 9, 10, 12)
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, trace: NexusDoubles::RUNNING_TRACE, conversation_events: [])
    daemon = member_ready(boot(clock: -> { now }), api)
    stale = { "parent" => "c-1", "tools" => "none", "opened_at" => (now - 90_000).iso8601,
              "last_turn_at" => (now - Rho::Daemon::Loops::SIDE_IDLE_TTL - 1).iso8601 }
    fresh = stale.merge("last_turn_at" => (now - Rho::Daemon::Loops::SIDE_IDLE_TTL + 60).iso8601)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "m/x")
    store.remember(conversation_host("c-1-side"), workspace: "ws-1", model: "m/x", notes: { "rho.side" => stale })
    store.remember(conversation_host("c-2-side"), workspace: "ws-1", model: "m/x", notes: { "rho.side" => fresh })
    store.remember(conversation_host("c-3-side"), workspace: "ws-other", model: "m/x", notes: { "rho.side" => stale })
    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")
    assert_includes daemon.lineage.runs.map(&:public_id), "c-1-side"

    swept = daemon.loops.sweep_sides(now)

    assert_equal %w[c-1-side c-3-side], swept
    assert_equal %w[c-1-side c-3-side], api.conversation_deletes, "the kernel's DELETE: tombstone and reap at once"
    assert_equal %w[c-1 c-2-side], store.rows.map(&:host_public_id).sort
    refute_includes daemon.lineage.runs.map(&:public_id), "c-1-side", "its follower ended"
    assert_empty daemon.loops.sweep_sides(now), "nothing left to sweep"
  end

  # The listing hides side hosts by default and shows them alone under
  # `?side=1`, each with its parent — `rho loops --side`.
  def test_the_followed_listing_hides_sides_by_default_and_lists_them_on_request
    api = kernel_api(user_public_id: IDENTITY.user_public_id)
    daemon = member_ready(boot(config: tiered), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x", compose: false)
    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")
    side(daemon, { "tools" => "none" })

    assert_equal %w[c-1], followed(daemon).map { |row| row.fetch("public_id") }
    sides = JSON.parse(request(daemon, :get, "/loops?side=1", token: bearer(daemon)).body).fetch("loops")
    assert_equal [["c-1-side", { "parent" => "c-1" }]], sides.map { |row| [row.fetch("public_id"), row.fetch("side")] }
  end
end
