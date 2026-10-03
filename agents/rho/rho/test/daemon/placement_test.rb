require "test_helper"

class DaemonPlacementTest < Minitest::Test
  include RhoTest::DaemonHarness

  # WHERE A BARE RELATIVE PATH LANDS. The runner's root took its own
  # default because nothing could state it, so every relative path a model
  # wrote resolved under a scratch directory instead of under the
  # operator's code — and `write` reported the argument, so nobody found
  # out.
  def test_the_operators_tools_root_reaches_the_tools
    stated = File.join(@root, "src")
    FileUtils.mkdir_p(stated)
    daemon = boot(config: Rho::Config.from_hash("tools_root" => stated))

    env = daemon.context.tool_env

    assert_equal stated, env.root
    # The root's captures are rho's bookkeeping: under the work
    # root, keyed by the root, never an `artifacts/` in the person's tree.
    assert_equal Rho::Runner::ToolEnv.artifacts_dir_for(root: stated, work_dir: daemon.home.work_root),
      env.artifacts_dir, "the root's captures are placed under the work root, keyed by the root"
    refute env.artifacts_dir.start_with?("#{stated}/"), "rho's bookkeeping inside the person's tree: #{env.artifacts_dir}"
    assert_equal 120, env.bash_timeout_seconds
  end

  # THE SHADOW STORE RIDES THE ENV: for a root OUTSIDE the
  # protected roots (a project of the person's, never under RHO_HOME) the
  # daemon hands the extension a callable member at boot, opens the store
  # for THAT root at placement under the home's work root, keyed by the
  # root's digest — the same object on every rebuild of one root — and the
  # two hidden names register beside the coding set.
  def test_a_project_root_opens_the_checkpoint_store_at_placement_and_registers_the_two_names
    Dir.mktmpdir("rho-project") do |project|
      daemon = boot(config: Rho::Config.from_hash("tools_root" => project))
      env = daemon.context.tool_env

      store = env.checkpoints
      assert_kind_of Rho::Runner::Checkpoints::Store, store
      assert_equal File.realpath(project), store.root
      assert_equal File.join(File.realpath(daemon.home.work_root), "checkpoints", Rho::Runner::Checkpoints::Store.digest(project)),
        store.path
      assert_equal 7, store.retention_days
      assert_equal 30.0, store.capture_timeout_seconds
      assert_same store, daemon.context.tool_env.checkpoints, "one store per root, opened once"
      assert_same store, daemon.host.checkpoints.call, "the extension's member answers the env's store"
      assert_includes daemon.context.registry.serving(:runner).names, "world_restore"
      assert_includes daemon.context.registry.serving(:runner).names, "checkpoints"
    end
  end

  # NO STORE, BY POLICY OR BY LAYOUT: `checkpoints.enabled:
  # false` opens none; a runner root inside a protected root — a stated
  # `tools_root` under one of RHO_HOME's members (the home's extension
  # code, config and credentials are never a project area; the work root
  # under the home is, see the default-layout pin below) — opens none
  # either: the member is nil at boot, nothing registers, nothing is
  # announced, the env carries no store.
  def test_checkpoints_open_no_store_when_disabled_or_when_the_work_root_is_protected
    Dir.mktmpdir("rho-project") do |project|
      disabled = boot(config: Rho::Config.from_hash("tools_root" => project, "checkpoints" => { "enabled" => false }))
      assert_nil disabled.host.checkpoints
      assert_nil disabled.context.tool_env.checkpoints
      refute_includes disabled.context.registry.names, "world_restore"
    end

    home = File.join(@root, "home")
    stated = File.join(home, "extensions", "src")
    FileUtils.mkdir_p(stated)
    under_home = boot(root: home, config: Rho::Config.from_hash("tools_root" => stated))
    assert_nil under_home.host.checkpoints, "a root under one of the home's protected members opens no store"
    assert_nil under_home.context.tool_env.checkpoints
    refute_includes under_home.context.registry.names, "world_restore"
    refute_includes under_home.context.registry.names, "checkpoints"
  end

  # THE DEFAULT INSTALL OPENS A STORE: under
  # the default layout — RHO_HOME a directory, RHO_WORK_DIR its `work/`, no
  # `tools_root`, `checkpoints.enabled` its default — the home's WORK root
  # is the person's project area by construction (the incubation denies,
  # `LoopRequest.self_modification_rules`, carry the checkout, the gem,
  # the install prefix and the home, and let the model write under the
  # work root), so the member is the callable and the placed runner's root
  # under it opens a store under `<work_root>/checkpoints/`. A work root
  # inside rho's OWN checkout or under the install prefix is still nobody's
  # project area: nil, as `checkpoints.enabled: false` is nil.
  def test_the_default_layout_opens_a_store_for_the_placed_runner_under_the_work_root
    daemon = boot(device_flow: connection_device_flow, api_transport: NexusDoubles::FakeAgentApi.new(
      workspaces: [{ public_id: "0199-workspace", name: "Helper", dedicated: true }]
    ))
    home = daemon.home
    assert_equal File.join(home.root, "work"), home.work_root, "the default layout: the work root under the home"
    assert_respond_to daemon.host.checkpoints, :call, "the member is the callable, decided at boot"
    token = connect(daemon)
    await_workspace_state(daemon, "adopted", token: token)
    wait_for { daemon.lineage.runners.length == 2 }

    store = daemon.context.tool_env.checkpoints
    assert_kind_of Rho::Runner::Checkpoints::Store, store
    assert_equal File.realpath(daemon.context.environment.root), store.root
    assert store.root.start_with?("#{File.realpath(home.work_root)}/"), "the runner's default root sits under the work root"
    assert_equal File.join(File.realpath(home.work_root), "checkpoints", Rho::Runner::Checkpoints::Store.digest(store.root)), store.path
    assert_same store, daemon.host.checkpoints.call
    assert_includes daemon.context.registry.serving(:runner).names, "world_restore"
    assert_includes daemon.context.registry.serving(:runner).names, "checkpoints"

    disabled = boot(root: File.join(@root, "off"), config: Rho::Config.from_hash("checkpoints" => { "enabled" => false }))
    assert_nil disabled.host.checkpoints
    refute_includes disabled.context.registry.names, "world_restore"

    inside_checkout = File.join(Rho.root, "tmp", "rho-boot-#{SecureRandom.hex(4)}")
    begin
      home_in_checkout = Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(@root, "in-checkout"),
        work_root: inside_checkout)
      under_checkout = Rho::Daemon.boot(home: home_in_checkout)
      @daemons << under_checkout
      assert_nil under_checkout.host.checkpoints, "a work root inside rho's own checkout opens no store"
      refute_includes under_checkout.context.registry.names, "world_restore"
      refute_includes under_checkout.context.registry.names, "checkpoints"
    ensure
      FileUtils.rm_rf(inside_checkout)
    end

    prefix = File.join(@root, "prefix")
    FileUtils.mkdir_p(prefix)
    previous = ENV["RHO_PREFIX"]
    begin
      ENV["RHO_PREFIX"] = prefix
      home_in_prefix = Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(@root, "in-prefix"),
        work_root: File.join(prefix, "work"))
      under_prefix = Rho::Daemon.boot(home: home_in_prefix)
      @daemons << under_prefix
      assert_nil under_prefix.host.checkpoints, "a work root under the install prefix opens no store"
      refute_includes under_prefix.context.registry.names, "world_restore"
    ensure
      previous.nil? ? ENV.delete("RHO_PREFIX") : ENV["RHO_PREFIX"] = previous
    end
  end

# THE HOME INSIDE THE RUNNER ROOT STAYS EXCLUDED: the home's members are
# protected roots wherever the work root lies (the work root alone is exempt, the members enumerated), so with the
# work root elsewhere and the home INSIDE the root the store captures
# (RHO_WORK_DIR=~ with RHO_HOME=~/.rho, the root bound at `~`) the
# member stands — the root is under no protected root — and the store
# carries every member of the home as a protected root, so its config
# and credentials never enter a tree ("no secret ever enters a store").
def test_a_home_inside_the_runner_root_is_still_a_protected_root_of_the_store
  area = File.join(@root, "area")
  home_root = File.join(area, ".rho")
  FileUtils.mkdir_p(home_root)
  File.write(File.join(area, "a.txt"), "a")
  # The person's own `artifacts/` is THEIRS: rho's captures live
  # under the work root keyed by the root, so nothing under the root is
  # rho's to skip wholesale — only its own capture directory, which here
  # (work root = root) lies inside the root, is excluded as the store
  # excludes itself.
  FileUtils.mkdir_p(File.join(area, "artifacts"))
  File.write(File.join(area, "artifacts", "theirs.txt"), "theirs")
  home = Rho::Home.resolve(base_url: "https://nexus.example", root: home_root, work_root: area)
  daemon = Rho::Daemon.boot(home: home, config: Rho::Config.from_hash("tools_root" => area))
  @daemons << daemon
  assert_respond_to daemon.host.checkpoints, :call, "the root is under no protected root: the member stands"

  store = daemon.context.tool_env.checkpoints
  assert_kind_of Rho::Runner::Checkpoints::Store, store
  assert_equal File.realpath(area), store.root
home.protected_members.each do |member|
  assert_includes store.protected_roots, Rho.spelled(member), "the home's members inside the root are excluded at capture"
end
refute_includes store.protected_roots, File.realpath(home_root), "the home's own entry is never a root"
  spill = File.join(daemon.context.tool_env.ensure_artifacts_dir!, "bash-deadbeef.log")
  File.write(spill, "spill")
  assert spill.start_with?("#{File.join(File.realpath(area), "artifacts")}/"),
    "the fixture: rho's captures inside the root here (#{spill})"
  record = store.capture(loop: "al-1")
  refute record.skip?, "the capture stands: #{record.inspect}"
  paths = IO.popen(["git", "--git-dir", store.path, "ls-tree", "-r", "--name-only", record.hash], &:read).split("\n")
  assert_includes paths, "a.txt"
  assert_includes paths, "artifacts/theirs.txt", "the person's own artifacts/ is captured: it is theirs, not rho's"
  assert_empty paths.grep(%r{\A\.rho/}), "no byte of the home is in the tree"
  assert_empty paths.grep(/bash-deadbeef/), "rho's own capture directory inside the root is excluded, as the store excludes itself"
end

  # THE ROOT MOVES UNDER A PLACED RUNNER: the
  # runner is never rebuilt and no root is stale — a claim resolves its
  # placement on the worker (`Toolsets#for`), and `rho env` rebuilds
  # PLACEMENT ZERO alone: a new env on the new root, its store, its
  # captures directory, the announcement written again. The extension's
  # member answers the context's placement store, zero's outside a call.
  def test_a_moved_root_rebuilds_placement_zero_and_the_runner_stands
    api = NexusDoubles::FakeAgentApi.new(workspaces: [{ public_id: "0199-workspace", name: "Helper", dedicated: true }])
    daemon = boot(device_flow: connection_device_flow, api_transport: api)
    # A project of the person's, beside the home (a root under RHO_HOME
    # outside its work root is protected and opens no store).
    moved = Dir.mktmpdir("rho-moved")
    token = connect(daemon)
    await_workspace_state(daemon, "adopted", token: token)
    wait_for { daemon.lineage.runners.length == 2 && api.runner_announcements.length == 1 }
    runner = daemon.lineage.runner(:runner)
    before = daemon.context.tool_env

    daemon.context.repoint_tools(moved)
    wait_for { api.runner_announcements.length == 2 }

    assert_same runner, daemon.lineage.runner(:runner), "the runner stands"
    refute_same before, daemon.context.tool_env, "placement zero is rebuilt, never mutated"
    assert_equal File.realpath(moved), File.realpath(daemon.context.tool_env.root)
    assert_equal File.realpath(moved), File.realpath(api.runner_announcements.last.dig("environment", "root")),
      "the announcement names the root the tools serve"
    assert_equal File.realpath(moved), daemon.context.tool_env.checkpoints.root
    assert_same daemon.context.tool_env.checkpoints, daemon.host.checkpoints.call, "zero's store outside a call"
    assert_equal Rho::Runner::ToolEnv.artifacts_dir_for(root: moved, work_dir: daemon.home.work_root),
      daemon.context.tool_env.artifacts_dir, "the captures follow the root of the moment, under the work root (H-4)"
  ensure
    FileUtils.remove_entry(moved) if moved && File.directory?(moved)
  end

  # THE RUNNER STARTS WITH THE WORKSPACE, because adoption is the first
  # instant it has anywhere to poll — and it reports itself, because an
  # operator asking "is this machine taking work?" deserves an answer that
  # is not "read the log".
  def test_the_runner_starts_when_a_workspace_is_adopted_and_reports_itself
    api = NexusDoubles::FakeAgentApi.new(
      workspaces: [{ public_id: "0199-workspace", name: "Helper", dedicated: true }]
    )
    daemon = boot(device_flow: connection_device_flow, api_transport: api)
    token = connect(daemon)
    await_workspace_state(daemon, "adopted", token: token)

    status = nil
    40.times do
      status = JSON.parse(request(daemon, :get, "/runner", token: token).body)["runner"]
      break if status && status["swept"].to_i.positive?

      sleep 0.05
    end

    assert status, "an adopted workspace must have a runner"
    assert status.fetch("running")
    assert_equal 0, status.fetch("in_flight")
    assert_includes status.fetch("tools"), "read"
    assert_includes status.fetch("tools"), "bash"
    assert_operator status.fetch("swept"), :>=, 1,
      "the inbox is the truth, so it is read without waiting to be told"
    assert_equal 0, status.fetch("nudged"), "nobody has told it anything yet"

    # `/status` serves both meters too: the pair is the diagnosis (a rising
    # `swept` beside `nudged: 0` is the latency path broken), and the
    # operator's one read must carry both.
    facts = JSON.parse(request(daemon, :get, "/status", token: token).body).fetch("runner")
    assert_operator facts.fetch("swept"), :>=, 1
    assert_equal 0, facts.fetch("nudged")
  end

  # THE TWO LOOPS OF FULL MODE: the runner address serves
  # this machine's tools, the agent address its own. Agent mode places the
  # agent's loop alone and registers no runner.
  def test_full_mode_places_both_loops_and_agent_mode_the_agents_alone
    api = NexusDoubles::FakeAgentApi.new(
      workspaces: [{ public_id: "0199-workspace", name: "Helper", dedicated: true }]
    )
    daemon = boot(device_flow: connection_device_flow, api_transport: api)
    token = connect(daemon)
    await_workspace_state(daemon, "adopted", token: token)
    wait_for { daemon.lineage.runners.length == 2 }

    document = JSON.parse(request(daemon, :get, "/runner", token: token).body)
    assert_includes document.fetch("runner").fetch("tools"), "bash"
    refute_includes document.fetch("runner").fetch("tools"), "summarize_history"
    assert_equal %w[summarize_history todo_write read_scheduled_jobs manage_scheduled_job], document.fetch("agent").fetch("tools"),
      "the agent serves summaries, todos and scheduled job management"
    wait_for { api.runner_inbox_reads.positive? && api.executor_inbox_reads.positive? }
    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    # 19 = the coding set with file import/publication, the processes pair, the store's two hidden
    # names — a default-layout home opens a store for its placed runner
    # (re-cut from 14 when the work root's exemption landed) — and the
    # environment's hidden `environment_bind`.
    assert_includes log, "event=executor.announced tools=19 address=runner"
    assert_includes log, "event=executor.announced tools=4 address=agent"

    agent = boot(device_flow: connection_device_flow, api_transport: NexusDoubles::FakeAgentApi.new(
      workspaces: [{ public_id: "0199-workspace", name: "Helper", dedicated: true }]
    ), config: agent_mode, root: File.join(@root, "agent"))
    token = connect(agent)
    await_workspace_state(agent, "adopted", token: token)
    wait_for { agent.lineage.runner(:agent_runner) }
    document = JSON.parse(request(agent, :get, "/runner", token: token).body)
    assert_nil document.fetch("runner")
    assert_equal %w[summarize_history todo_write read_scheduled_jobs manage_scheduled_job], document.fetch("agent").fetch("tools")
    assert_nil agent.identity.runner_executor_public_id
  end

  # RUNNER MODE CONSTRUCTS NO MEMBER PLANE: a boot under the
  # fake records ZERO requests under the member credential, mounts no page,
  # registers no conversation routes, announces a runner-shaped identity and
  # places its one loop from adoption — no workspace.
  def test_a_runner_mode_boot_touches_no_member_resource
    api = NexusDoubles::FakeAgentApi.new
    daemon = boot(device_flow: connection_device_flow, api_transport: api, config: runner_mode)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    body = await_state(daemon, "active", token: token)
    wait_for { api.runner_inbox_reads.positive? }

    assert_nil daemon.loops, "no Loops, so no HostStore behind it"
    refute_predicate daemon, :page?
    assert_equal "404", get(daemon, "/nope").code
    assert_equal "not_found", JSON.parse(get(daemon, "/nope").body).dig("error", "code")
    %w[/conversations /say /stop /compact /loops].each do |path|
      response = request(daemon, :post, path, token: token, body: {})
      assert_equal "404", response.code, path
      assert_equal "not_found", JSON.parse(response.body).dig("error", "code"), path
    end
    assert_equal "404", request(daemon, :get, "/loops", token: token).code

    assert_equal "runner", body["mode"]
    refute body.key?("workspace"), "a runner adopts no workspace"
    # The status names the install too (the home's instance id); the
    # announcement below is the lineage's own facts and carries none.
    assert_equal({ "executor_public_id" => "0199-runner", "runner_executor_public_id" => "0199-runner",
                   "instance_id" => daemon.home.instance_id },
      body.fetch("identity"))
    assert_equal ["runner_transport"], body.dig("authority", "planes").keys
    assert_equal({ "executor_public_id" => "0199-runner", "runner_executor_public_id" => "0199-runner" },
      announcement(daemon).fetch("identity"))
    document = JSON.parse(request(daemon, :get, "/runner", token: token).body)
    assert_includes document.fetch("runner").fetch("tools"), "read"
    assert_nil document.fetch("agent")
    assert_empty(api.requests.select { |_path, credential, _| credential == NexusDoubles::MEMBER_TOKEN },
      "zero requests under the member credential")
    assert_empty api.announcements, "nothing on the agent address"
    assert_equal 1, api.runner_announcements.length
    refute_nil api.runner_announcements.first["environment"]
    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    # 19: the store's two hidden names announce on a default-layout home
    # too (re-cut from 14 with the work root's exemption), and the
    # environment's hidden `environment_bind` — a runner-mode rho is told
    # its conversations' root sets by the host.
    assert_includes log, "event=executor.announced tools=19 address=runner"
    assert_equal "connected", JSON.parse(request(daemon, :get, "/environment", token: token).body).dig("environment", "root").then { |root| root ? "connected" : "unset" }
    assert_includes daemon.context.environment.root, File.join("runners", "0199-runner")
  end
end
