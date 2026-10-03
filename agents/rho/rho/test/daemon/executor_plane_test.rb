require "test_helper"
require "cybros_agent/test_support/fake_realtime"

# THE EXECUTOR PLANE OUT OF `Loops`: the runner address's loop, its announcement and its
# nudge stream, driven on the RUNNER credential — the cases `loops_test` pinned through
# `Loops` before runner mode existed, re-homed with their subjects, not loosened.
class DaemonExecutorPlaneTest < Minitest::Test
  include RhoTest::DaemonHarness

  # ---- the executor socket ----
  #
  # A SECOND CABLE ON THE TRANSPORT CREDENTIAL: the runner's nudges ride
  # `ExecutorInboxChannel`, keyed by the executor the bearer names — no
  # params — and never the member socket the followers share. The cable is
  # latency only; the sweep is the truth, and E4 proves the product works
  # without it. The daemon holds the socket on the lineage and closes it
  # on every edge, the way it closes the member socket.

  EXECUTOR_CHANNEL = "AgentAPI::V1::ExecutorInboxChannel".freeze
  RUNNER_WORKSPACE = { public_id: "0199-workspace", name: "Helper", dedicated: true }.freeze

  def inbox_row(key, tool: "ls", input: { "path" => "." })
    { "kind" => "tool_call", "agent_loop_public_id" => "al-1", "conversation_public_id" => nil,
      "parent_public_id" => nil, "task_key" => key, "tool_name" => tool,
      "tool_input" => input, "tool_call_id" => "call-#{key}", "started_at" => "2026-09-07T00:00:00Z",
      "deadline_at" => nil, "claimed" => false,
      "addressed_to" => { "role" => "runner", "executor_public_id" => "0199-runner" } }
  end

  # One cable double per plane, handed out by the credential the lineage
  # mints each socket with — the factory is called once per plane.
  def cabled(api, **options)
    fakes = { NexusDoubles::MEMBER_TOKEN => CybrosAgent::TestSupport::FakeRealtime.new,
              NexusDoubles::TRANSPORT_TOKEN => CybrosAgent::TestSupport::FakeRealtime.new,
              NexusDoubles::RUNNER_TOKEN => CybrosAgent::TestSupport::FakeRealtime.new }
    daemon = boot(device_flow: connection_device_flow, api_transport: api,
      realtime_factory: ->(credential) { fakes.fetch(credential.call.to_s) }, **options)
    token = connect(daemon)
    await_workspace_state(daemon, "adopted", token: token)
    [daemon, token, fakes.fetch(NexusDoubles::RUNNER_TOKEN), fakes.fetch(NexusDoubles::MEMBER_TOKEN),
     fakes.fetch(NexusDoubles::TRANSPORT_TOKEN)]
  end

  def runner_document(daemon, token)
    JSON.parse(request(daemon, :get, "/runner", token: token).body).fetch("runner")
  end

  def frame(type, key, **extra)
    { "event" => { "type" => type, "agent_loop_public_id" => "al-1", "task_key" => key }.merge(extra) }
  end

  def test_the_executor_socket_subscribes_the_inbox_channel_with_no_params_on_each_addresss_credential
    api = NexusDoubles::FakeAgentApi.new(workspaces: [RUNNER_WORKSPACE])
    _daemon, _token, executor, member, agent = cabled(api)

    wait_for { executor.subscriptions.any? && agent.subscriptions.any? }
    assert_equal [[EXECUTOR_CHANNEL, {}]], executor.subscriptions.map { |sub| [sub.channel, sub.params] },
      "the credential names the address: nothing to pass"
    assert_equal [[EXECUTOR_CHANNEL, {}]], agent.subscriptions.map { |sub| [sub.channel, sub.params] },
      "the agent address's own socket, on its own credential"
    assert_empty member.subscriptions, "the member socket carries feeds, never the inbox"
    wait_for { api.runner_inbox_reads.positive? }
    assert(api.requests.none? { |path, _| path.include?("agent_loop_task_inbox") }, "no member-plane inbox read")
  end

  def test_a_work_available_frame_of_kind_tool_call_reaches_the_runner_as_a_nudge
    api = NexusDoubles::FakeAgentApi.new(workspaces: [RUNNER_WORKSPACE])
    daemon, token, executor, = cabled(api)
    wait_for { executor.subscriptions.any? && runner_document(daemon, token).fetch("swept").positive? }
    api.stock_inbox(inbox_row("t1"), address: :runner)

    assert_equal 1, executor.deliver(EXECUTOR_CHANNEL, frame("work_available", "t1", "kind" => "tool_call", "tool_name" => "ls"))

    wait_for { api.commits.length == 1 }
    assert_equal ["t1"], api.claims, "claiming IS the fetch: nudged, then claimed on the executor plane"
    key, body = api.commits.fetch(0)
    assert_equal "t1", key
    assert_equal "completed", body.fetch("outcome")
    assert_equal "tok-t1", body.fetch("claim_token")
    document = runner_document(daemon, token)
    assert_equal 1, document.fetch("nudged")
    assert_equal 1, document.fetch("claimed")
    assert_equal 0, document.fetch("canceled")
  end

  def test_a_work_canceled_frame_reaches_the_runner_by_loop_and_task_key
    api = NexusDoubles::FakeAgentApi.new(workspaces: [RUNNER_WORKSPACE],
      runner_inbox_tasks: [inbox_row("t1", tool: "bash", input: { "command" => "sleep 30" })])
    daemon, token, executor, = cabled(api)
    wait_for { executor.subscriptions.any? && runner_document(daemon, token).fetch("in_flight") == 1 }

    executor.deliver(EXECUTOR_CHANNEL, frame("work_canceled", "t1"))

    wait_for { api.commits.length == 1 }
    _key, body = api.commits.fetch(0)
    assert_equal "failed", body.fetch("outcome")
    assert_includes body.fetch("content"), "interrupted"
    document = runner_document(daemon, token)
    assert_equal 1, document.fetch("canceled")
    assert_equal 0, document.fetch("in_flight")
  end

  def test_a_work_canceled_frame_leaves_the_same_task_key_in_another_loop_running
    release_path = File.join(@root, "release-other-loop")
    other_command = "while [ ! -e #{release_path} ]; do sleep 0.01; done; echo other-loop-finished"
    api = NexusDoubles::FakeAgentApi.new(workspaces: [RUNNER_WORKSPACE], runner_inbox_tasks: [
      inbox_row("t1", tool: "bash", input: { "command" => "sleep 30" }),
      inbox_row("t1", tool: "bash", input: { "command" => other_command }).merge("agent_loop_public_id" => "al-2"),
    ])
    daemon, token, executor, = cabled(api)
    wait_for { executor.subscriptions.any? }
    executor.deliver(EXECUTOR_CHANNEL,
      frame("work_available", "t1", "kind" => "tool_call", "agent_loop_public_id" => "al-2"))
    wait_for { runner_document(daemon, token).fetch("in_flight") == 2 }

    executor.deliver(EXECUTOR_CHANNEL, frame("work_canceled", "t1"))
    wait_for { api.commits.any? }
    File.write(release_path, "go")
    wait_for { api.commits.length == 2 }

    assert_equal %w[completed failed], api.commits.map { |_key, body| body.fetch("outcome") }.sort
    completed = api.commits.find { |_key, body| body["outcome"] == "completed" }
    assert_includes completed&.last&.fetch("content"), "other-loop-finished"
    assert_equal 0, runner_document(daemon, token).fetch("in_flight")
  end

  # An `ask` frame is the agent application's notice, never the runner's
  # work: it is written down as the daemon's ask notice and
  # never dispatched — the inbox is the level-triggered truth `rho status`
  # reads — and the next tool_call frame still lands.
  def test_an_ask_frame_is_noted_and_never_dispatched
    api = NexusDoubles::FakeAgentApi.new(workspaces: [RUNNER_WORKSPACE])
    daemon, token, executor, = cabled(api)
    wait_for { executor.subscriptions.any? && runner_document(daemon, token).fetch("swept").positive? }
    api.stock_inbox(inbox_row("t1"), address: :runner)

    executor.deliver(EXECUTOR_CHANNEL, frame("work_available", "a1", "kind" => "ask"))
    executor.deliver(EXECUTOR_CHANNEL, frame("work_available", "t1", "kind" => "tool_call", "tool_name" => "ls"))

    wait_for { api.commits.length == 1 }
    assert_equal ["t1"], api.claims, "the ask was never taken"
    assert_equal 1, runner_document(daemon, token).fetch("nudged"), "the ask counted for nothing"
    wait_for { File.read(daemon.home.log_path, encoding: Encoding::UTF_8).include?("executor.ask_available") }
    notice = File.read(daemon.home.log_path, encoding: Encoding::UTF_8).lines.grep(/executor\.ask_available/).first
    assert_includes notice, "loop=al-1"
    assert_includes notice, "task=a1"
  end

  # THE PARK'S NUDGE: an `approval` frame is the agent
  # application's row — a call held for a person — noted as the daemon's
  # approval notice and never dispatched (the pool never sees it; the
  # inbox read lists it and claims nothing); the next tool_call frame
  # still lands.
  def test_an_approval_frame_is_noted_and_never_dispatched
    api = NexusDoubles::FakeAgentApi.new(workspaces: [RUNNER_WORKSPACE])
    daemon, token, executor, = cabled(api)
    wait_for { executor.subscriptions.any? && runner_document(daemon, token).fetch("swept").positive? }
    api.stock_inbox(inbox_row("t1"), address: :runner)

    executor.deliver(EXECUTOR_CHANNEL, frame("work_available", "r1t0", "kind" => "approval", "tool_name" => "bash"))
    executor.deliver(EXECUTOR_CHANNEL, frame("work_available", "t1", "kind" => "tool_call", "tool_name" => "ls"))

    wait_for { api.commits.length == 1 }
    assert_equal ["t1"], api.claims, "the held call was never taken"
    assert_equal 1, runner_document(daemon, token).fetch("nudged"), "the park counted for nothing"
    wait_for { File.read(daemon.home.log_path, encoding: Encoding::UTF_8).include?("executor.approval_available") }
    notice = File.read(daemon.home.log_path, encoding: Encoding::UTF_8).lines.grep(/executor\.approval_available/).first
    assert_includes notice, "loop=al-1"
    assert_includes notice, "task=r1t0"
  end

  # E4's unit twin: with the socket off, no executor subscription is opened
  # and the sweep alone carries the work — `nudged: 0` beside `claimed: 1`.
  def test_with_the_executor_socket_off_the_sweep_still_claims
    api = NexusDoubles::FakeAgentApi.new(workspaces: [RUNNER_WORKSPACE], runner_inbox_tasks: [inbox_row("t1")])
    daemon, token, executor, = cabled(api, config: Rho::Config.from_hash("executor_socket" => false))

    wait_for { api.commits.length == 1 }
    assert_empty executor.subscriptions
    assert_nil daemon.lineage.executor_realtime, "no socket was minted"
    assert_nil daemon.lineage.executor_realtime(:agent_runner)
    document = runner_document(daemon, token)
    assert_operator document.fetch("swept"), :>, 0
    assert_equal 0, document.fetch("nudged")
    assert_equal 1, document.fetch("claimed")
  end

  # ONE SOCKET PER LINEAGE: `rho env` rebuilds the
  # RUNNER — reserve, build, install, announce, follow — and nothing else.
  # The executor socket is the lineage's and was opened on adoption; the
  # declaration reads the registry, not the root; the store's rows are
  # already followed. A second placement that re-ran the whole edge opened
  # the socket twice (`already connected — call #close before reconnecting`,
  # a second `profile.declared`, a second readopt). The nudge fiber reads
  # the runner of the moment, so a frame after the repoint lands on the
  # NEW runner through the ONE subscription.
  # A TOOLS REPOINT REANNOUNCES, NEVER REBUILDS: placement zero is rebuilt — a new env, toolset and
  # store on the new root — and `Daemon#reannounce(:runner)` writes the
  # root's document again under the slot's credential; the runner, its
  # meters and the one executor socket stand.
  def test_a_tools_repoint_reannounces_the_runners_document_without_a_rebuild
    api = NexusDoubles::FakeAgentApi.new(workspaces: [RUNNER_WORKSPACE])
    daemon, token, executor, = cabled(api)
    wait_for { executor.subscriptions.any? && runner_document(daemon, token).fetch("swept").positive? }
    wait_for { api.configuration_declarations.length == 1 }
    before = daemon.lineage.runner
    swept_before = runner_document(daemon, token).fetch("swept")
    root = File.join(@root, "elsewhere")
    FileUtils.mkdir_p(root)

    response = request(daemon, :post, "/environment", token: token, body: { "root" => root })

    assert_equal "200", response.code, response.body
    wait_for { api.runner_announcements.length == 2 }
    assert_same before, daemon.lineage.runner, "the runner stands: only placement zero moved"
    assert_equal File.realpath(root), File.realpath(api.runner_announcements.last.dig("environment", "root")),
      "the announcement names the new root"
    assert_kind_of String, api.runner_announcements.last.dig("environment", "booted_at"), "and this daemon's boot"
    assert_equal api.runner_announcements.first.dig("environment", "booted_at"),
      api.runner_announcements.last.dig("environment", "booted_at"), "constant across re-points"
    assert_equal File.realpath(root), daemon.context.tool_env.checkpoints.root, "the store follows the root"
    assert_operator runner_document(daemon, token).fetch("swept"), :>=, swept_before, "the meters never restart"
    assert_equal 1, executor.subscriptions.length, "the lineage's socket, opened once on adoption"
    assert_equal 1, api.configuration_declarations.length, "the declaration reads the registry, not the root"
    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    refute_includes log, "executor_nudge_stream_ended", "no second connect on the one client"
    assert_equal 1, log.scan("event=profile.declared").length

    api.stock_inbox(inbox_row("t1"), address: :runner)
    assert_equal 1, executor.deliver(EXECUTOR_CHANNEL, frame("work_available", "t1", "kind" => "tool_call", "tool_name" => "ls"))

    wait_for { api.commits.length == 1 }
    assert_equal ["t1"], api.claims
    document = runner_document(daemon, token)
    assert_equal 1, document.fetch("nudged"), "the frame reached the runner of the moment"
    assert_equal 1, document.fetch("claimed")
  end

  # A MOVED SERVER SET REANNOUNCES THE AGENT SLOT: the editor's servers bound
  # through the door land on the AGENT address's list — the registry's
  # entries ∪ every anchor's servers, a name once — written again under
  # the agent's own credential (`reannounce(:agent_runner)`), the runner
  # address untouched; the profile's union is declared once for the set
  # (its digest gate), an equal list moves nothing, and the close
  # announces the registry's list alone again. The runner itself stands.
  def test_a_moved_server_set_reannounces_the_agent_slot_and_declares_the_union_once
    closes = File.join(@root, "closes.txt")
    api = NexusDoubles::FakeAgentApi.new(workspaces: [RUNNER_WORKSPACE])
    daemon, token, executor, = cabled(api,
      config: Rho::Config.from_hash("extension_paths" => [RhoTest::ConversationServers.extension(@root, closes: closes)]))
    wait_for { executor.subscriptions.any? && runner_document(daemon, token).fetch("swept").positive? }
    wait_for { api.configuration_declarations.length == 1 && api.announcements.length == 1 }
    agent_before = api.announcements.length
    runner_before = api.runner_announcements.length
    registry_names = api.announcements.last.fetch("tools").map { |tool| tool.fetch("name") }
    runner = daemon.lineage.runner
    src = File.join(@root, "src")
    FileUtils.mkdir_p(src)
    store = host_store(daemon)
    store.remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: daemon.lineage.member_plane_snapshot.first.public_id,
      model: "m/x", runner: daemon.lineage.identity.runner_executor_public_id)
    bind = ->(body) { request(daemon, :post, "/conversations/environment", token: token, body: { public_id: "c-1" }.merge(body)) }
    assert_equal "200", bind.call(root: src).code

    response = bind.call(mcp: [RhoTest::ConversationServers.stdio("fx")])

    assert_equal "200", response.code, response.body
    wait_for { api.announcements.length == agent_before + 1 }
    announced = api.announcements.last.fetch("tools").map { |tool| tool.fetch("name") }
    assert_equal (registry_names + %w[mcp__fx__lookup mcp__fx__paths]).sort, announced.sort, "the registry's ∪ the anchor's, a name once"
    assert_equal announced, announced.sort, "sorted by name as the registry's own list is"
    fx = api.announcements.last.fetch("tools").find { |tool| tool.fetch("name") == "mcp__fx__lookup" }
    assert_equal ["lookup on fx", { "type" => "object", "properties" => { "q" => { "type" => "string" } } }],
      fx.values_at("description", "input_schema"), "the declaration facts a peer authors from"
    assert_equal runner_before, api.runner_announcements.length, "the runner address is not touched"
    assert_same runner, daemon.lineage.runner, "nothing rebuilt"
    assert_equal 2, api.configuration_declarations.length, "the union declared once for the set"
    names = api.configuration_declarations.last.dig("configuration", "tool_definitions").map { |e| e.dig("function", "name") }
    assert_includes names, "mcp__fx__lookup"
    assert_equal 1, names.count("bash"), "this machine's own entries stay, once"
    assert_equal 2, File.read(daemon.home.log_path, encoding: Encoding::UTF_8).scan("event=profile.declared").length

    assert_equal "200", bind.call(mcp: [RhoTest::ConversationServers.stdio("fx")]).code
    sleep 0.2
    assert_equal agent_before + 1, api.announcements.length, "an equal list: no announcement"
    assert_equal 2, api.configuration_declarations.length, "and no declaration"

    assert_equal "200", bind.call(mcp: []).code
    wait_for { api.announcements.length == agent_before + 2 }
    assert_equal registry_names.sort, api.announcements.last.fetch("tools").map { |tool| tool.fetch("name") }.sort, "closed: the registry's alone"
    assert_equal 3, api.configuration_declarations.length
    refute_includes api.configuration_declarations.last.dig("configuration", "tool_definitions").map { |e| e.dig("function", "name") }, "mcp__fx__lookup"
    assert_equal ["c-1"], File.read(closes).split("\n")
    assert_equal runner_before, api.runner_announcements.length
  end

  # THE METERS ARE THE RUNNER'S OWN: with no
  # rebuild there is nothing to carry, and `/status` serves the one
  # runner's counts — a nudge after a repoint lands on the same runner.
  def test_a_tools_repoint_keeps_the_runners_meters_because_nothing_is_rebuilt
    api = NexusDoubles::FakeAgentApi.new(workspaces: [RUNNER_WORKSPACE])
    daemon, token, executor, = cabled(api)
    wait_for { executor.subscriptions.any? && runner_document(daemon, token).fetch("swept").positive? }
    api.stock_inbox(inbox_row("t1"), address: :runner)
    executor.deliver(EXECUTOR_CHANNEL, frame("work_available", "t1", "kind" => "tool_call", "tool_name" => "ls"))
    wait_for { api.commits.length == 1 }
    root = File.join(@root, "elsewhere")
    FileUtils.mkdir_p(root)

    response = request(daemon, :post, "/environment", token: token, body: { "root" => root })

    assert_equal "200", response.code, response.body
    wait_for { api.runner_announcements.length == 2 }
    api.stock_inbox(inbox_row("t2"), address: :runner)
    executor.deliver(EXECUTOR_CHANNEL, frame("work_available", "t2", "kind" => "tool_call", "tool_name" => "ls"))
    wait_for { api.commits.length == 2 }

    assert_equal 2, runner_document(daemon, token).fetch("nudged"), "the same runner counted both"
    assert_equal 2, status_runner(daemon, token).fetch("nudged"), "and /status serves the runner's own count"
  end

  # `/status`'s runner block: the one runner's counts.
  def status_runner(daemon, token)
    JSON.parse(request(daemon, :get, "/status", token: token).body).fetch("runner")
  end

  def test_agent_loss_closes_only_its_executor_socket
    api = NexusDoubles::FakeAgentApi.new(workspaces: [RUNNER_WORKSPACE])
    daemon, _token, executor, _member, agent = cabled(api)
    wait_for { executor.subscriptions.any? && agent.subscriptions.any? }
    assert_same executor, daemon.lineage.executor_realtime

    daemon.send(:lose_authority)

    wait_for { agent.closed? }
    assert_nil daemon.lineage.executor_realtime(:agent_runner), "the Agent's slot retired its socket"
    refute executor.closed?, "the independent Runner transport remains usable"
    assert_same executor, daemon.lineage.executor_realtime
  end

  # THE RUNNER HALF LOST: its slot and socket retire alone; the
  # agent's own loop and socket stand, the daemon stays active.
  def test_losing_the_runner_lineage_retires_the_runner_slot_and_its_socket_alone
    api = NexusDoubles::FakeAgentApi.new(workspaces: [RUNNER_WORKSPACE])
    daemon, token, executor, _member, agent = cabled(api)
    wait_for { executor.subscriptions.any? && agent.subscriptions.any? }
    about = daemon.lineage.credentials

    assert daemon.maintenance.renewal_event(:lost, about, lineage: :runner)

    wait_for { executor.closed? }
    refute agent.closed?, "the agent address's socket stands"
    assert_nil daemon.lineage.runner(:runner)
    refute_nil daemon.lineage.runner(:agent_runner)
    refute about.runner?
    body = JSON.parse(request(daemon, :get, "/status", token: token).body)
    assert_equal "active", body["state"]
    assert_equal "0199-runner", body.dig("identity", "runner_executor_public_id"), "the identity keeps the id"
    assert_nil body["runner"]["tools"], "local truth: no runner slot"
    assert_includes File.read(daemon.home.log_path, encoding: Encoding::UTF_8), "runner.authority_lost"
  end

  def test_stopping_the_daemon_closes_the_executor_socket
    api = NexusDoubles::FakeAgentApi.new(workspaces: [RUNNER_WORKSPACE])
    daemon, _token, executor, = cabled(api)
    wait_for { executor.subscriptions.any? }

    daemon.stop

    assert_predicate executor, :closed?, "stop returns only after the owner reactor closed it"
  end
end
