require "support/daemon_run_helpers"

class DaemonHostFollowersTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  # ---- side conversations: rho's bookkeeping over the kernel's side fork ----

  def side(daemon, body)
    response = request(daemon, :post, "/side", token: bearer(daemon), body: body)
    [response.code, JSON.parse(response.body)]
  end

  def side_note(public_id) = store.find(public_id).notes.fetch(Rho::Daemon::HostFollowers::SIDE_NOTE)

  # One reusable side retains the ordinary declaration and adds its posture
  # as a user tail. Read narrows that declaration on subsequent turns.
  def test_side_forks_the_newest_conversation_once_and_reuses_the_open_side
    # The page is the test's to release (`page`), once the question went
    # out: a side just forked has no turn to replay, and the fake's
    # unconditional page raced the route's `before` read — won by whichever
    # side paid the runner root's first `tool_env` build (the checkpoint
    # store's open). And no real time: the follower is the REST one (no
    # socket — a test daemon's socket to nexus.example never opens, and
    # the feed's transient budget on it timed the second `/events` read
    # at 29.9 s, a hair under the 30 s bound; beside two worlds it crossed
    # it: the `KeyError "run_public_id"`), its poll and the wait's are one yield
    # each, and the bound is the injected clock's, which stands still
    # until the page exists — a starved machine cannot spend it.
    page = Queue.new
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: page)
    now = Time.utc(2026, 9, 6)
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil },
      clock: -> { page.empty? ? now : (now += Rho::Daemon::HostFollowers::MATERIALIZATION_POLL) },
      sleeper: ->(_seconds) { sleep 0.001 }), api)
    store.remember(conversation_host("c-0"), workspace: "ws-1", model: "openrouter/old")
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1",
      model: "openrouter/x")

    asking = Thread.new { side(daemon, { "tools" => "write", "text" => "what are you doing?" }) }
    wait_for { api.conversation_inputs.any? }
    page << true
    code, answer = asking.value

    assert_equal "201", code, answer.inspect
    assert_equal({ "public_id" => "c-1-side" }, answer.fetch("side"))
    assert_equal({ "public_id" => "c-1" }, answer.fetch("parent"), "the newest live conversation, never c-0")
    assert_equal({ "public_id" => "al-1" }, answer["run"],
      "the turn materialized, as `do` waits for it — the route answered #{answer.inspect}")
    assert_equal [["c-1", { "fork" => { "side" => true } }]], api.forks, "the kernel's side fork, no turn named"
    input = api.conversation_inputs.fetch(0).fetch("input")
    assert_equal ["direct_reply", "what are you doing?", "queue", { "model" => "openrouter/x" }, nil],
      input.values_at("kind", "text", "delivery_mode", "model", "approval_mode")
    request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "carry on" })
    parent_input = api.conversation_inputs.fetch(1).fetch("input")
    refute parent_input.key?("tool_names"), "the parent and side both use the full declaration"
    refute_equal [], input["tool_names"]
    refute input.key?("tool_names"), "the own-answerer side keeps the parent's declaration"
    refute parent_input.key?("approval_mode"), "the parent and side use their ordinary approval policy"
    tail, *rest = input.fetch("inline")
    assert_empty rest, "ONE inline entry"
    assert_equal %w[user tail], [tail.fetch("role"), tail.fetch("position")]
    assert_equal Rho::Daemon::HostFollowers::SIDE_LEADS.fetch("write"), tail.fetch("text")
    assert(api.requests.any? { |path, _| path.end_with?("/conversations/c-1-side/inputs") }, "on the SIDE's door")
    row = store.find("c-1-side")
    assert_equal ["conversation", "openrouter/x"], [row.host_type, row.model]
    assert_nil row.answerer, "rho's own answerer keeps the ordinary tool selection path"
    assert_equal "c-1", side_note("c-1-side").fetch("parent")
    assert_equal "write", side_note("c-1-side").fetch("tools")
    refute_nil side_note("c-1-side")["last_turn_at"]
    assert_includes daemon.lineage.followers.map(&:public_id), "c-1-side", "the side is followed"

    code, answer = side(daemon, { "tools" => "read" })
    assert_equal "200", code, answer.inspect
    assert_equal({ "public_id" => "c-1-side" }, answer.fetch("side"))
    assert answer.fetch("reused")
    assert_equal 1, api.forks.length, "the open side is reused, never forked again"
    assert_equal 2, api.conversation_inputs.length, "no text, no input"
    assert_equal "read", side_note("c-1-side").fetch("tools"), "the posture moves with the last open"

    code, answer = side(daemon, { "parent_public_id" => "c-1-side", "tools" => "write" })
    assert_equal "200", code, answer.inspect
    assert_equal "c-1-side", answer.dig("side", "public_id"), "the side's own id names it too"
    assert_equal "c-1", answer.dig("parent", "public_id")

    assert_equal "400", side(daemon, { "tools" => "unknown" }).first
    assert_equal "400", side(daemon, { "tools" => "none" }).first
    assert_equal "404", side(daemon, { "parent_public_id" => "c-nope", "tools" => "write" }).first
  end

  # A SECOND QUESTION ON THE REUSED SIDE waits for ITS OWN run. The side's
  # follower still holds the first question's settled run (`al-1`) until
  # the next turn's first item resets it, and the wait `do` taught this
  # route must not answer the first run it saw. With no second turn on the feed the honest answer
  # is `pending`, never `al-1`; the clock is stepped so the bound elapses.
  def test_a_second_question_on_the_reused_side_waits_for_its_own_run_and_never_answers_the_last_ones
    api = kernel_api(user_public_id: IDENTITY.user_public_id)
    now = Time.utc(2026, 9, 12, 12)
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }, clock: -> { now += 60 }, sleeper: ->(_) { }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x")

    code, = side(daemon, { "tools" => "write", "text" => "what are you doing?" })
    assert_equal "201", code
    wait_for { daemon.host_followers.followed("al-1")&.public_id == "c-1-side" }

    code, answer = side(daemon, { "tools" => "write", "text" => "try a tool" })

    assert_equal "200", code, answer.inspect
    assert answer.fetch("reused")
    assert_equal 2, api.conversation_inputs.length, "the second question went out on the side"
    refute_equal({ "public_id" => "al-1" }, answer["run"], "the LAST question's run, answered as this one's")
    assert answer.fetch("pending"), "no run was minted for this question, so nothing else is named: #{answer.inspect}"
  end

  def test_side_approval_requests_remain_available_for_a_person
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    workspace = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1")
    attention = Rho::HostFollower::Attention.new(reason: "approval_required", blocked_task_keys: ["r1t2"])

    %w[read write].each do |tools|
      host = conversation_host("c-#{tools}-side")
      store.remember(host, workspace: "ws-1", notes: { "rho.side" => { "parent" => "c-parent", "tools" => tools } })
      run = nil
      capturing_spawns(daemon) do
        run = daemon.host_followers.adopt_follower(host, host.context(workspace), {}, runs: workspace.runs)
      end

      daemon.host_followers.follow_attention(run, attention, workspace.runs, "al-side", hosted: host.context(workspace))
    end

    assert_empty api.adjudications, "Side never automatically approves or denies the person's pending decisions"
  end

  def test_an_active_side_recovers_its_policy_after_follower_cache_eviction
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    host = conversation_host("c-active-side")
    note = { "parent" => "c-parent", "tools" => "write", "last_turn_at" => Time.now.iso8601 }
    store.remember(host, workspace: "ws-1", model: "dev/side", notes: { "rho.side" => note })
    workspace = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1")
    run = nil
    capturing_spawns(daemon) do
      run = daemon.host_followers.adopt_follower(host, host.context(workspace), {}, runs: workspace.runs)
    end
    Rho::HostStore::MAX_ROWS.times { |index| store.remember(run_host("cached-#{index}"), workspace: "ws-1") }
    assert_nil store.find(host.public_id)

    daemon.host_followers.send(:follow_turn, run, host.context(workspace))

    assert_empty api.adjudications
    assert_equal "write", store.find(host.public_id).notes.dig("rho.side", "tools")
  end

  def test_an_evicted_sides_failed_policy_read_is_retried_before_its_next_turn
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    host = conversation_host("c-active-side")
    store.remember(host, workspace: "ws-1", notes: { "rho.side" => { "parent" => "c-parent", "tools" => "write" } })
    workspace = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1")
    hosted = host.context(workspace)
    run = nil
    capturing_spawns(daemon) { run = daemon.host_followers.adopt_follower(host, hosted, {}, runs: workspace.runs) }
    Rho::HostStore::MAX_ROWS.times { |index| store.remember(run_host("cached-#{index}"), workspace: "ws-1") }
    original_call = api.method(:call)
    api.define_singleton_method(:call) do |path, **options|
      if path.include?("/store_entries") && options.fetch(:method, :get) == :get
        CybrosAgent::Response.new(status: 503, headers: {}, body: nil)
      else
        original_call.call(path, **options)
      end
    end

    assert_raises(CybrosAgent::Api::Error) do
      daemon.host_followers.send(:follow_turn, run, hosted)
    end
    assert_nil store.find(host.public_id), "a failed read must not cache an unverified empty policy"
    assert_empty api.adjudications
    api.define_singleton_method(:call, original_call)

    daemon.host_followers.send(:follow_turn, run, hosted)

    assert_empty api.adjudications
    assert_equal "write", store.find(host.public_id).notes.dig("rho.side", "tools")
  end

  # `say` on a side row applies the posture's subset and the tail on
  # every turn, and never a developer lead — where a plain conversation
  # carries one on every say.
  def test_say_on_a_side_applies_the_read_subset_and_the_tail_and_never_a_lead
    api = kernel_api(user_public_id: IDENTITY.user_public_id)
    now = Time.utc(2026, 9, 10, 12)
    daemon = member_ready(boot(config: catalog_config, clock: -> { now += 60 }), api, identity: RUNNER_IDENTITY)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x", runner: RUNNER_IDENTITY.runner_executor_public_id)
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
    refute_includes names, "task"
    assert_equal names, Rho::Daemon::HostFollowers::READ_ONLY_SUBSET & names, "rho's list, in rho's order"
    assert_equal [{ "role" => "user", "position" => "tail", "text" => Rho::Daemon::HostFollowers::SIDE_LEADS.fetch("read") }],
      input.fetch("inline"), "the tail alone: no lead on a side, where a plain turn carries one every say"
    assert_equal "steer", input.fetch("delivery_mode")
    refute_equal before, side_note("c-1-side").fetch("last_turn_at"), "a turn keeps the side alive"
  end

  def test_a_side_uses_the_selected_model_on_the_first_submission_and_its_replay
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }), api)

    %w[write read].each_with_index do |tools, index|
      parent_id = "c-#{index + 1}"
      store.remember(conversation_host(parent_id), workspace: "ws-1", model: "openrouter/old")
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

  def test_a_read_side_keeps_its_inherited_runners_read_callable_and_excludes_writes
    readers = %w[runner-a runner-b].map do |runner|
      NexusDoubles.remote_runner(runner,
        tools: [NexusDoubles.served_tool("read"), NexusDoubles.served_tool("write")])
    end
    api = kernel_api(user_public_id: IDENTITY.user_public_id, executors: readers, conversation_events: [])
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x", runner: "runner-a")
    store.remember(conversation_host("c-2"), workspace: "ws-1", model: "openrouter/x", runner: "runner-b")
    code, opened = side(daemon, { "parent_public_id" => "c-1", "tools" => "read" })
    assert_equal "201", code, opened.inspect

    response = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: opened.fetch("side").fetch("public_id"), text: "Read the inherited tree", wait: false })

    assert_equal "200", response.code, response.body
    names = api.conversation_inputs.last.fetch("input").fetch("tool_names")
    expected = ["read"]
    assert_equal expected.sort, names.sort
  end

  def test_a_read_side_refuses_tool_expansion
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x")
    code, opened = side(daemon, { "tools" => "read" })
    assert_equal "201", code, opened.inspect
    side_id = opened.fetch("side").fetch("public_id")

    response = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: side_id, text: "Tighter", wait: false, tool_names: ["bash"] })
    assert_equal "400", response.code, response.body
    assert_match(/posture/, JSON.parse(response.body).dig("error", "message"))
    assert_empty api.conversation_inputs
  end

  def test_a_side_defaults_to_the_answerers_tools_and_preserves_approval_tightening
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }), api, identity: RUNNER_IDENTITY)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x", runner: RUNNER_IDENTITY.runner_executor_public_id)
    code, opened = side(daemon, {})
    assert_equal "201", code, opened.inspect
    assert_equal "write", opened.fetch("tools")
    assert_equal "write", side_note("c-1-side").fetch("tools")

    [nil, "ask", "rules"].each do |approval|
      fields = { public_id: "c-1-side", text: "Make the change", delivery_mode: "queue", wait: false }
      fields[:approval_mode] = approval if approval
      response = request(daemon, :post, "/say", token: bearer(daemon), body: fields)
      assert_equal "200", response.code, response.body
      input = api.conversation_inputs.last.fetch("input")
      refute input.key?("tool_names"), "write uses the ordinary whole declaration"
      if approval
        assert_equal approval, input.fetch("approval_mode")
      else
        refute input.key?("approval_mode"), "an omitted tightening uses the answerer's policy"
      end
      assert_equal [Rho::Daemon::HostFollowers::SIDE_LEADS.fetch("write")], input.fetch("inline").map { |entry| entry.fetch("text") }
    end
  end

  def test_side_approval_inputs_preserve_the_requested_tightening
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x")

    %w[read write].each do |tools|
      side(daemon, { "tools" => tools })
      %w[bypass ask rules].each do |approval|
        response = request(daemon, :post, "/say", token: bearer(daemon),
          body: { public_id: "c-1-side", text: "Continue", wait: false, approval_mode: approval })
        assert_equal "200", response.code, response.body
        input = api.conversation_inputs.last.fetch("input")
        assert_equal approval, input.fetch("approval_mode")
      end
    end
  end

  def test_a_side_initial_question_carries_approval_and_invalid_approval_opens_nothing
    api = kernel_api(user_public_id: IDENTITY.user_public_id)
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x")

    code, = side(daemon, { "text" => "Make a change", "approval_mode" => "invalid" })
    assert_equal "400", code
    assert_empty api.forks
    assert_empty api.conversation_inputs

    code, = side(daemon, { "text" => "Make a change", "approval_mode" => "ask" })
    assert_equal "201", code
    input = api.conversation_inputs.last.fetch("input")
    assert_equal "ask", input.fetch("approval_mode")
    refute input.key?("tool_names")
    assert_equal [Rho::Daemon::HostFollowers::SIDE_LEADS.fetch("write")], input.fetch("inline").map { |entry| entry.fetch("text") }
  end

  def test_a_side_can_further_narrow_its_tools_without_changing_its_posture
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }), api, identity: RUNNER_IDENTITY)

    %w[read write].each_with_index do |tools, index|
      parent_id = "c-#{index + 1}"
      store.remember(conversation_host(parent_id), workspace: "ws-1", model: "openrouter/x", runner: RUNNER_IDENTITY.runner_executor_public_id)
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
        refute first.key?("approval_mode")
        assert_equal [Rho::Daemon::HostFollowers::SIDE_LEADS.fetch(tools)], first.fetch("inline").map { |entry| entry.fetch("text") }
      end
      assert_equal tools, side_note(side_id).fetch("tools"), "input narrowing does not rewrite the side's posture"
    end
  end

  def test_a_side_refuses_a_malformed_tool_subset_before_submitting_input
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x")
    side(daemon, { "tools" => "read" })

    response = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "c-1-side", text: "Malformed", tool_names: "read", wait: false })

    assert_equal "400", response.code, response.body
    assert_match(/tool_names must be a list/, JSON.parse(response.body).dig("error", "message"))
    assert_empty api.conversation_inputs
  end

  def test_a_foreign_side_uses_the_forks_answerer_without_sending_the_personal_tool_subset
    child = { "public_id" => "c-1-side", "answering_user_public_id" => "fork-answerer", "side" => true,
              "parent" => { "public_id" => "c-1" }, "context_revision" => 0,
              "created_at" => "2026-09-30T00:00:00Z", "updated_at" => "2026-09-30T00:00:00Z",
              "usage_summary" => { "request_count" => 0, "input_tokens" => 0, "cache_read_tokens" => 0,
                "uncached_input_tokens" => 0, "cache_creation_tokens" => 0, "output_tokens" => 0,
                "reasoning_tokens" => 0, "total_tokens" => 0, "cost_amount" => "0.0", "cost_complete" => true,
                "cost_unit" => nil },
              "input_queue" => { "limit" => 16, "held" => 0 }, "access" => { "default" => "full", "entries" => [] } }
    forked = CybrosAgent::Response.new(status: 201, headers: {},
      body: { "conversation" => child, "runner_effects" => { "status" => "untouched", "runners" => [] } })
    api = kernel_api(user_public_id: IDENTITY.user_public_id, fork: forked, conversation_events: [])
    now = Time.utc(2026, 9, 30)
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil },
      clock: -> { now += 60 }, sleeper: ->(_) { }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x",
      answerer: "parent-answerer")

    code, answer = side(daemon, { "parent_public_id" => "c-1", "tools" => "write", "text" => "a side question" })

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
      refute input.key?("approval_mode"), "the foreign answerer retains its approval policy"
      assert_equal [{ "role" => "user", "position" => "tail", "text" => Rho::Daemon::HostFollowers::SIDE_LEADS.fetch("write") }],
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
    stale = { "parent" => "c-1", "tools" => "write", "opened_at" => (now - 90_000).iso8601,
              "last_turn_at" => (now - Rho::Daemon::HostFollowers::SIDE_IDLE_TTL - 1).iso8601 }
    fresh = stale.merge("last_turn_at" => (now - Rho::Daemon::HostFollowers::SIDE_IDLE_TTL + 60).iso8601)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "m/x")
    store.remember(conversation_host("c-1-side"), workspace: "ws-1", model: "m/x", notes: { "rho.side" => stale })
    store.remember(conversation_host("c-2-side"), workspace: "ws-1", model: "m/x", notes: { "rho.side" => fresh })
    store.remember(conversation_host("c-3-side"), workspace: "ws-other", model: "m/x", notes: { "rho.side" => stale })
    daemon.host_followers.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")
    assert_includes daemon.lineage.followers.map(&:public_id), "c-1-side"

    swept = daemon.host_followers.sweep_sides(now)

    assert_equal %w[c-1-side c-3-side], swept
    assert_equal %w[c-1-side c-3-side], api.conversation_deletes, "the kernel's DELETE: tombstone and reap at once"
    assert_equal %w[c-1 c-2-side], store.rows.map(&:host_public_id).sort
    refute_includes daemon.lineage.followers.map(&:public_id), "c-1-side", "its follower ended"
    assert_empty daemon.host_followers.sweep_sides(now), "nothing left to sweep"
  end

  # The listing hides side hosts by default and shows them alone under
  # `?side=1`, each with its parent — `rho runs --side`.
  def test_the_followed_listing_hides_sides_by_default_and_lists_them_on_request
    api = kernel_api(user_public_id: IDENTITY.user_public_id)
    daemon = member_ready(boot(config: catalog_config), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "openrouter/x")
    daemon.host_followers.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")
    store.remember(conversation_host("review-side"), workspace: "ws-1", model: "openrouter/x",
      notes: { Rho::MemoryReview::NAMESPACE => { "parent" => "c-1" } })
    daemon.host_followers.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")
    side(daemon, { "tools" => "write" })

    assert_equal "c-1", api.forks.last.first, "the automatic review side never becomes the interactive side parent"
    assert_includes daemon.context.followers.map(&:public_id), "review-side", "quiet work keeps its control and recovery follower"
    assert_equal %w[c-1], followed(daemon).map { |row| row.fetch("public_id") }
    sides = JSON.parse(request(daemon, :get, "/followers?side=1", token: bearer(daemon)).body).fetch("followers")
    assert_equal [["c-1-side", { "parent" => "c-1" }]], sides.map { |row| [row.fetch("public_id"), row.fetch("side")] }
  end
end
