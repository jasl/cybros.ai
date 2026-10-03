require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/contract_fixtures"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# The rho dedication and StoreEntry lane, one ordered scenario under the dedicated rho steward Human
# — the unique steward isolates rho's fixed product identifier from every other test on the shared
# Nexus. Fresh device flow and daemon boot create exactly one dedicated private Workspace; a restart
# lists-and-adopts it without duplicating; a second Agent under the same steward proves the
# dedication fence while the Human owner stays unfenced; StoreEntry CRUD, replay, mismatch, and
# key_taken ride the same Workspace; the store's other two hosts — a conversation of that Workspace
# and the acting principal's own profile — are observed beside it; and the steward finally hands the
# row to the founding owner with the creator unchanged.
#
# SHARED PLUMBING, STATED: every test in this file drives the SAME signed-in
# steward browser (E2E::StewardSession, one per journey process); the
# daemon, its RHO_HOME and every ceremony stay per test.
class WorkspaceDedicationTest < Minitest::Test
  FENCE_AGENT_IDENTIFIER = "cybros-e2e-fence-agent".freeze

  def setup
    @base_url = E2E.base_url
    @entries_pack = E2E::ContractFixtures.store_entries
    @errors_pack = E2E::ContractFixtures.errors
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-workspace-e2e")
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    sign_in_steward
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(File.join(@home, "log", "rho.log"), "rho structured log") if @home
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/workspace_dedication-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture rho workspace E2E capture: #{error.class}: #{error.message}"
  ensure
    [@daemon, @second].compact.each do |daemon|
      daemon.stop
    rescue StandardError => error
      warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
    end
    [@home, @second&.home].compact.each { |home| FileUtils.remove_entry(home) if File.directory?(home) }
  end

  def test_rho_dedicates_one_workspace_fences_other_agents_and_hands_it_to_the_founding_owner
    steward_client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)

    # Fresh Agent device flow plus daemon boot: the daemon discovers no
    # dedicated Workspace and creates exactly one, private, without waiting
    # for a renewal interval.
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    adopted = await_workspace_state("adopted")
    workspace_public_id = adopted.dig("workspace", "public_id")
    rho_profile_public_id = adopted.dig("identity", "user_public_id")
    refute_nil workspace_public_id
    refute_nil rho_profile_public_id

    rows = dedicated_rows(steward_client, creator: rho_profile_public_id)
    assert_equal [workspace_public_id], rows.map(&:public_id), "exactly one dedicated Workspace exists for this rho"
    summary = rows.first
    assert summary.dedicated, "the only public dedication marker is the boolean"
    assert_equal "private", summary.access_mode, "an Agent create always forces private"
    assert_equal "active", summary.state

    # The Full projection proves the ownership triangle: the steward Human
    # owns, the rho Agent Profile created, and the daemon's announced name
    # is the row's name.
    full = steward_client.workspaces.fetch(workspace_public_id)
    assert_equal @steward.public_id, full.owner.public_id
    assert_equal rho_profile_public_id, full.creator.public_id
    assert_equal "agent", full.creator.kind
    assert_equal adopted.dig("workspace", "name"), full.name

    # TWO HOMES UNDER ONE STEWARD: a second install of the SAME program on a second RHO_HOME
    # presents `rho.<its own instance>` — the id derived at its first boot, never typed — and pairs
    # as a SEPARATE Profile with its own dedicated Workspace. The kernel publishes no identifier
    # (the product-code tag reaches no public surface), so the two rows are read as two creators and
    # the two ids from each home's `instance.json` and its `rho status`.
    second_home, second_profile_public_id, second_workspace_public_id = pair_a_second_home(steward_client)
    refute_equal rho_profile_public_id, second_profile_public_id, "a second home is a second Profile, not a re-pair"
    refute_equal workspace_public_id, second_workspace_public_id
    assert_equal [second_workspace_public_id], dedicated_rows(steward_client, creator: second_profile_public_id).map(&:public_id)
    assert_equal [workspace_public_id], dedicated_rows(steward_client, creator: rho_profile_public_id).map(&:public_id),
      "the first install's dedication is untouched by the second"

    # A restart lists before it ever creates: the same Workspace is adopted
    # and no sibling appears — and, after the second install paired, the
    # restart is the kernel-proven fact that it FENCED NOTHING: a fenced
    # device could not adopt (its grant would be revoked by the re-pair).
    @daemon.stop
    @daemon.start
    readopted = await_workspace_state("adopted")
    assert_equal workspace_public_id, readopted.dig("workspace", "public_id"),
      "a restart adopts the same dedicated Workspace"
    assert_equal rho_profile_public_id, readopted.dig("identity", "user_public_id"), "the same Profile: the same home"
    assert_equal [workspace_public_id], dedicated_rows(steward_client, creator: rho_profile_public_id).map(&:public_id),
      "a restart never duplicates the dedicated Workspace"
    first_status, = @daemon.cli("status")
    assert_match(/^instance:  #{instance_id(@home)}$/, first_status, first_status)
    refute_match(/^state:     (not connected|credentials expired)/, first_status, "the first install is still connected:\n#{first_status}")
    FileUtils.remove_entry(second_home) if File.directory?(second_home)

    # All daemon assertions are done; stop it so a later maintenance cycle
    # cannot race the transfer at the end of the lane.
    @daemon.stop

    # The steward Human is never fenced: full StoreEntry CRUD rides this
    # Workspace, including replay, mismatch, and key_taken.
    entries = steward_client.workspace(workspace_public_id).store_entries
    entry = verify_store_entry_crud_prelude(entries)

    # A second Agent under the same steward with a different identifier:
    # reads pass, every write is fenced with the dedication mismatch, and
    # owner management stays server-side.
    fence_client = verify_dedication_fence(workspace_public_id, entry)

    # The store's other two hosts on the same Workspace: a conversation's
    # (fenced through its workspace) and each principal's own profile
    # (never fenced, per principal, no receipt).
    verify_store_hosts(steward_client, workspace_public_id, fence_client)

    # The steward completes the CRUD: update to a stored JSON null, then
    # delete to the family's one empty answer.
    verify_store_entry_crud_epilogue(entries, entry)

    # Finally the steward hands the Workspace to the founding owner; the
    # creator remains the rho Agent Profile.
    current = steward_client.workspaces.fetch(workspace_public_id)
    handed = steward_client.workspace(workspace_public_id).transfer_ownership(
      target_user_public_id: @world.owner_public_id, lock_version: current.lock_version
    )
    assert_equal @world.owner_public_id, handed.owner.public_id
    assert_equal rho_profile_public_id, handed.creator.public_id, "transfer never rewrites the creator"
    assert_equal "agent", handed.creator.kind
  end

  # THE WHOLE CHAIN, AND THE ONE PIECE THAT HAD NEVER BEEN CONNECTED.
  #
  # Nexus has parked tool work for a runner, but nothing had ever walked through those doors. Here a
  # person gives rho work through rho's own door, a real rho subprocess on this machine claims the
  # tool task the model fanned and runs a real shell command, and the kernel feeds that answer to a
  # model round — which is what lets the loop complete.
  #
  # WORK IS ADDRESSED, NEVER BROADCAST. A tool call goes to the host's bound runner or to the loop's
  # declaring agent's address, by what that executor ANNOUNCED — never to whoever in the workspace
  # has write standing. The runner a host binds is the one its creator NAMES: the daemon's own
  # identity is the EXPECTATION, and discovery is how a person FINDS it — the steward lists the
  # runners they may address, picks rho's by what it announced (its names, its root) and names it on
  # the shell, and gets (i) `tool_not_served` at start for a tool nobody announces — an error, never
  # a ten-minute park — and (ii) a completed `bash` whose row is addressed to that runner and whose
  # answer is this machine's shell. The last half is how a person gives rho work: through rho's
  # door, where the loop is rho's agent's and its calls land on rho's own runner.
  def test_a_person_gives_rho_work_and_the_loop_completes
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    adopted = await_workspace_state("adopted")
    workspace_public_id = adopted.dig("workspace", "public_id")
    rho_runner = adopted.dig("identity", "runner_executor_public_id")
    refute_nil rho_runner, "a full-mode rho registers a runner row: #{adopted["identity"].inspect}"
    # READINESS BY ANNOUNCEMENT (r-modes M1): the runner is placed on a spawned task after the
    # adoption edge — the checkpoint store's open sits in that placement — and its names reach the
    # kernel by one synchronous PUT; discovery lists what that PUT carried, so the read waits for
    # the fact it asserts.
    @daemon.await_announced(address: "runner")

    # THE PERSON FINDS THE RUNNER THROUGH DISCOVERY: rho's runner is private
    # to the profiles its steward manages, so it is listed for the steward,
    # with the names it announced and the root its relative paths resolve
    # against — the facts a person picks a runner by. Presence rides the
    # document and is never the reason to choose.
    steward_client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    named = steward_client.executors.list(kind: "runner").find { |executor| executor.public_id == rho_runner }
    refute_nil named, "discovery never listed rho's runner for its steward"
    assert_includes named.tool_names, "bash", "the runner announced its environment tools: #{named.tool_names.inspect}"
    assert_equal @daemon.control(:get, "/environment").dig("environment", "root"), named.environment["root"],
      "the announced root is where this machine's tools are pointed"
    rho_runner = named.public_id

    E2E.enable_dev_lane!
    # BOTH HOSTS, the deployment shape. Pinning one is for journeys that
    # assert WHICH host executed a turn; this one asserts that the graph
    # advances at all, and the graph advances on the queue worker — a
    # runner-only composition leaves every task waiting forever.
    E2E.hosts.start

    # (i) A tool nobody announces, on a host bound to rho's runner.
    unserved_public_id = author_and_start(workspace_public_id, rho_runner,
      { tool: { key: "t1", name: "slow_write", input: { seconds: 1 } } })
    attention = await_loop_status("needs_attention") do
      agent_api(:get,
        "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{unserved_public_id}")["agent_loop"]
    end
    hand_authored = attention.fetch("tasks").find { |task| task.fetch("key") == "t1" }
    assert_equal "failed", hand_authored.fetch("status"), hand_authored.inspect
    assert_equal({ "key" => "tool_not_served", "detail" => "no executor announces slow_write for this principal" },
      hand_authored.fetch("error"),
      "the bound runner announces no `slow_write` and no agent declares this loop, so nobody serves it")

    # (ii) `bash`, which rho's runner announces: the row is addressed to it
    # and the answer is this machine's shell.
    marker = "served-by-rhos-runner-#{SecureRandom.hex(4)}"
    served_public_id = author_and_start(workspace_public_id, rho_runner,
      { tool: { key: "t1", name: "bash", input: { command: "echo #{marker}" } } })
    served = await_loop_completion do
      agent_api(:get,
        "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{served_public_id}")["agent_loop"]
    end
    served_task = served.fetch("tasks").find { |task| task.fetch("key") == "t1" }
    assert_equal "completed", served_task.fetch("status"), served_task.inspect
    assert_equal({ "role" => "runner", "executor_public_id" => rho_runner, "presence" => "online" },
      served_task.fetch("addressed_to").except("last_seen_at"),
      "the row was addressed to the runner the creator named")
    served_detail = agent_api(:get, "/agent_api/v1/workspaces/#{workspace_public_id}" \
      "/agent_loops/#{served_public_id}/tasks/t1")
    assert_includes served_detail.dig("task", "output").to_s, marker, "rho's runner ran the person's command"

    started = @daemon.control(:post, "/loops", body: {
      prompt: "!mock tool_call=bash tool_args=#{CGI.escape(JSON.generate({ "command" => "echo hello-from-rho" }))} " \
              "-- report what the command printed",
      model: "dev/mock-text",
    })
    loop_public_id = started.dig("loop", "public_id")
    refute_nil loop_public_id, "rho answered #{started.inspect}"
    assert_equal "running", started.dig("loop", "status"),
      "the loop must be running before anything can be parked for a runner: #{started.inspect}"

    # THE RUNNER IS NEVER TOLD BY THIS TEST. It learns from the cable, or
    # from its own sweep — either one is the product working.
    completed = await_loop_completion do
      agent_api(:get,
        "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{loop_public_id}")["agent_loop"]
    end

    tool_task = completed.fetch("tasks").find { |task| task.fetch("kind") == "tool_task" }
    refute_nil tool_task, "the model never called a tool: #{completed.fetch("tasks").inspect}"
    assert_equal "bash", tool_task.fetch("tool_name")
    assert_equal "completed", tool_task.fetch("status"),
      "rho claimed the parked tool task and answered it: #{tool_task.inspect}"
    assert_nil tool_task["error"], "the shell ran"

    detail = agent_api(:get, "/agent_api/v1/workspaces/#{workspace_public_id}" \
      "/agent_loops/#{loop_public_id}/tasks/#{tool_task.fetch("key")}")
    assert_includes detail.dig("task", "output").to_s, "hello-from-rho",
      "the answer that came back is the one this machine produced"

    assert_equal({ "role" => "runner", "executor_public_id" => rho_runner, "presence" => "online" },
      tool_task.fetch("addressed_to").except("last_seen_at"),
      "rho's own door named its own runner row for the host")

    runner = @daemon.control(:get, "/runner").fetch("runner")
    assert_equal runner.fetch("tools").length, runner.fetch("announced"),
      "the address announced every tool it loaded before it followed — which is why the call reached it"
    assert_operator runner.fetch("claimed"), :>=, 2,
      "the daemon's own report agrees it did the work: the person's row and the model's"
    # TWO METERS, AND THE PAIR IS THE DIAGNOSIS. Work done with `nudged: 0`
    # means the sweep carried it alone — the product working and the latency
    # path silently broken, which is the one failure a passing journey would
    # otherwise hide.
    assert_operator runner.fetch("nudged"), :>=, 1,
      "the cable never delivered a nudge; the run was carried by polling alone"
  end

  # RHO STARTS ITS OWN WORK, and declares what it can do while doing it.
  #
  # The journey above authors the loop with raw HTTP and names `bash` by
  # hand — which is what every caller had to do, because nothing in this
  # repository could author an agent loop at all. This one goes through
  # `POST /loops`: rho reads its own extension registry, lowers those
  # declarations into the provider's shape, authors the task with them and
  # starts it. Nexus is never told what this machine can run — a
  # server-side capability record must never influence a round's tool
  # list — so if the declarations are wrong, the model is offered a tool
  # that does not exist and the round dies. That it completes is the proof
  # the carried declarations are right.
  def test_rho_authors_its_own_loop_with_the_tools_it_serves
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    adopted = await_workspace_state("adopted")
    workspace_public_id = adopted.dig("workspace", "public_id")

    E2E.enable_dev_lane!
    E2E.hosts.start

    started = @daemon.control(:post, "/loops", body: {
      prompt: "!mock tool_call=bash tool_args=#{CGI.escape(JSON.generate({ "command" => "echo hello-from-rho-do" }))} " \
              "-- report what the command printed",
      model: "dev/mock-text",
    })

    # THE DECLARATIONS ARE THIS MACHINE'S, not a list the test wrote — plus what the KERNEL does for
    # the model, which comes from a different place and must be visible as a different thing. rho
    # fetches those bytes from the published catalog rather than carrying a copy, because a
    # declaration that is not byte-identical to the registry's is refused `kernel_tool_redefined`.
    # `skill` is the kernel's load, declared by default: the DECLARATION carries it whether or not
    # this checkout holds a skill — the kernel omits it at the wire alone while the merged catalog
    # is empty.
    assert_equal %w[ask bash cancel compose edit file_import file_publish find grep list_processes ls manage_scheduled_job
                    memory_delete memory_edit memory_grep memory_ls memory_read memory_write read read_process read_scheduled_jobs
                    send session_read session_search skill spawn
                    start_process status stop_process task todo_write write],
      started.fetch("tools").sort,
      "rho declared its own registry's tools, including the todo tracker and scheduled jobs, " \
      "and the kernel tools it was configured with"
    loop_public_id = started.dig("loop", "public_id")
    refute_nil loop_public_id, "rho answered #{started.inspect}"
    assert_equal "running", started.dig("loop", "status")

    completed = await_loop_completion do
      agent_api(:get,
        "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{loop_public_id}")["agent_loop"]
    end

    # The model was offered rho's tools, chose one, and rho's own runner
    # executed it — the whole chain, with nothing in the middle that a
    # test wrote.
    tool_task = completed.fetch("tasks").find { |task| task.fetch("kind") == "tool_task" }
    refute_nil tool_task, "the model never called a tool: #{completed.fetch("tasks").inspect}"
    assert_equal "bash", tool_task.fetch("tool_name")
    assert_equal "completed", tool_task.fetch("status"), tool_task.inspect

    detail = agent_api(:get, "/agent_api/v1/workspaces/#{workspace_public_id}" \
      "/agent_loops/#{loop_public_id}/tasks/#{tool_task.fetch("key")}")
    assert_includes detail.dig("task", "output").to_s, "hello-from-rho-do",
      "the answer came from this machine's shell"

    addresses = @daemon.control(:get, "/runner")
    runner = addresses.fetch("runner")
    # What the RUNNER address executes: the coding tools and the process table's — this machine's
    # environment. The delegate summarizer the kernel addresses by policy is the AGENT address's
    # own, served there and never offered to the model (r-modes: two addresses, one registry
    # partitioned). `files_bytes` and `process_log` are the person's reads through the relay: served
    # here, announced described to nobody, hidden from every model by name. `skill` is the third
    # such name: the KERNEL's `skill` is what a profile declares and a model calls; the runner's
    # announced one is where the kernel delivers a load of a name this runner announced under
    # `documents` — hidden the same way. The checkpoint store's two are the fourth and fifth: a
    # default-layout home opens a store for its placed runner (the work root under RHO_HOME is the
    # person's project area), `world_restore` the person's rewind and `checkpoints` its read, both
    # announced described to nobody (re-cut from fourteen names with the work-root exemption).
    # `environment_bind` is the sixth: the hidden RUNNER tool a host elsewhere relays a
    # conversation's root set through — SERVED here, so the relay can address it, and NEVER
    # DECLARED: `undeclared` by name, so it reaches no model (the loop's declaration above holds no
    # such name) and the toolset stays byte-identical across placements.
    assert_equal %w[bash checkpoints edit environment_bind file_import file_publish files_bytes find grep list_processes ls process_log read
                    read_process skill start_process stop_process world_restore write],
      runner.fetch("tools").sort
    assert_equal %w[summarize_history todo_write read_scheduled_jobs manage_scheduled_job], addresses.fetch("agent").fetch("tools"),
      "the agent address serves the delegate, todo tracker and scheduled jobs: #{addresses["agent"].inspect}"
    assert_empty runner.fetch("extension_failures"),
      "an extension that failed to load is a product fact, and there should be none here"
    inventory = runner.fetch("extensions")
    # The committed set is the whole default set: every extension registers a tool, a hook, a
    # describer, a route, a command or a flag — `rho.checkpoints` among them, its two tools
    # announced only where the daemon opened a store (not this home's root), and `rho.todo`, the
    # tracker on the agent address, and `rho.scheduled_jobs`, the conversation's background-job
    # tools on the same address; `rho.agents` supplies the named-definition tools, the named
    # definitions' scanner and verbs, and `rho.images` (the pre-bench build), the image tool gated
    # on `image_model`; plus `rho.dev`, the development gem this bare home names (the harness writes
    # it before the boot) — the conversation verbs, never a tool. `rho.webui`
    # supplies the browser console routes, `rho.setup` registers terminal setup, and
    # `rho.settings` and inactive `rho.ingress_telegram` supply configuration routes and commands,
    # all without adding model tools. Telegram polling starts only after explicit enablement.
    assert_equal %w[rho.agents rho.checkpoints rho.coding rho.compaction rho.console_link rho.conventions rho.dev
                    rho.environment rho.guard rho.handoff rho.images rho.ingress_telegram rho.ops rho.processes
                    rho.scheduled_jobs rho.settings rho.setup rho.todo rho.until rho.webui],
      inventory.map { |entry| entry.fetch("name") }.sort,
      "the default set plus the dev extension this home names arrives through the extension plane, not a frozen table"
  end

  # THE VERBS AN OPERATOR TYPES, against a real daemon. Every backend
  # capability needs an entry point outside the UI — that is what makes it
  # debuggable while it is being built, and a route with no CLI verb
  # cannot be exercised until somebody builds a screen for it.
  def test_the_cli_reads_and_moves_where_the_tools_are_pointed
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    await_workspace_state("adopted")

    shown, status = @daemon.cli("env")
    assert_predicate status, :success?, shown
    assert_match(/^tools:\s+\S/, shown)
    # nobody has pointed them yet
    assert_match(/^source:\s+default/, shown)

    project = File.join(@home, "checkout")
    FileUtils.mkdir_p(project)
    moved, status = @daemon.cli("env", project)
    assert_predicate status, :success?, moved
    assert_includes moved, project
    assert_match(/^source:\s+api/, moved)

    # And it stuck, read back through the daemon rather than the same verb.
    assert_equal project, @daemon.control(:get, "/environment").dig("environment", "root")

    listed, status = @daemon.cli("runner")
    assert_predicate status, :success?, listed
    assert_includes listed, "extension: rho.coding"
    assert_includes listed, "bash"

    # ONE EXECUTOR SOCKET PER LINEAGE: the repoint rebuilt the runner and nothing else — no second
    # connect on the one client (`already connected — call #close before reconnecting`), and the
    # declaration written once, on adoption.
    rho_log = File.read(File.join(@home, "log", "rho.log"), encoding: Encoding::UTF_8)
    refute_includes rho_log, "executor_nudge_stream_ended", "the lineage's socket was opened once"
    assert_equal 1, rho_log.scan("event=profile.declared").length, "declared on adoption, not again on repoint"
  end

  # THE PAIRED TOOL ROUND, which had no end-to-end coverage at all.
  #
  # The journey above authors the tool task itself, so its output reaches
  # the model as an ordinary user message. This is the other shape and the
  # one the tool protocol exists for: a MODEL asks for a tool, the kernel
  # fans a task from the call, a runner on this machine answers it, and the
  # result returns to the model as a `function_call_output` paired to the
  # call by id. Four processes and a fake provider have to agree, and until
  # the mock learned to make a call and to SEE a result, none of it could
  # be observed.
  def test_a_model_asks_for_a_tool_and_reads_the_answer_it_gets_back
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    workspace_public_id = await_workspace_state("adopted").dig("workspace", "public_id")

    E2E.enable_dev_lane!
    E2E.hosts.start

    marker = "paired-#{SecureRandom.hex(4)}"
    # Through rho's own door: the loop is rho's agent's, so the call the model makes is addressed to
    # rho's address by what it announced — and the `bash` the model is offered is the one this
    # machine declared, not a copy a test wrote. The seed step's key is `work`.
    started = @daemon.control(:post, "/loops", body: {
      prompt: "!mock tool_call=bash tool_args=" \
              "#{CGI.escape(JSON.generate({ "command" => "echo #{marker}" }))} -- run it",
      model: "dev/mock-text",
    })
    loop_public_id = started.dig("loop", "public_id")
    refute_nil loop_public_id, "rho answered #{started.inspect}"
    assert_equal "running", started.dig("loop", "status"), started.inspect

    completed = await_loop_completion do
      agent_api(:get,
        "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{loop_public_id}")["agent_loop"]
    end

    tasks = completed.fetch("tasks")
    # THE KERNEL MINTED A TASK FROM THE CALL. Nothing in this journey
    # authored it — the fan is what turned the model's request into work a
    # runner could see.
    fanned = tasks.find { |task| task.fetch("kind") == "tool_task" }
    refute_nil fanned, "the kernel never fanned a task from the call: #{tasks.inspect}"
    assert_equal "bash", fanned.fetch("tool_name")
    assert_equal "completed", fanned.fetch("status"), "rho claimed it and answered"

    detail = agent_api(:get, "/agent_api/v1/workspaces/#{workspace_public_id}" \
      "/agent_loops/#{loop_public_id}/tasks/#{fanned.fetch("key")}")
    assert_includes detail.dig("task", "output").to_s, marker,
      "the shell on this machine ran the command the MODEL chose"

    # AND THE RESULT CAME BACK TO THE MODEL. The fake echoes what it was
    # sent, so a continuation round whose answer carries the marker is the
    # proof that the tool result reached the model as a paired
    # `function_call_output` — the whole point of the protocol, and the one
    # thing no test could observe before.
    spine = tasks.select { |task| task.fetch("kind") == "model_task" }
    assert_operator spine.length, :>=, 2,
      "the kernel appends a continuation round to read the answer: #{spine.inspect}"
    answers = spine.map do |task|
      agent_api(:get, "/agent_api/v1/workspaces/#{workspace_public_id}" \
        "/agent_loops/#{loop_public_id}/tasks/#{task.fetch("key")}").dig("task", "output").to_s
    end
    assert answers.any? { |answer| answer.include?(marker) },
      "no round ever saw the tool's answer: #{answers.inspect}"

    # THE PICTURE AS EVIDENCE: the chain the kernel grew — round, the tool it fanned, the
    # continuation that read it — is readable whole from a terminal, and the Mermaid text names the
    # same edges. Driven through the CLI, which is where a person would look.
    continuation = spine.map { |task| task.fetch("key") }.reject { |key| key == "work" }.first
    mermaid, status = @daemon.cli("graph", loop_public_id)
    assert_predicate status, :success?, mermaid
    assert_match(/\Aflowchart TD$/, mermaid, mermaid)
    ids = mermaid.scan(/^\s+(n\d+)\[{1,2}"([^ "]+) /).to_h { |id, key| [key, id] }
    assert_equal "#{ids.fetch("work")} --> #{ids.fetch(fanned.fetch("key"))}",
      mermaid[/^\s+(#{ids.fetch("work")} --> #{ids.fetch(fanned.fetch("key"))})$/, 1],
      "the round fans the tool:\n#{mermaid}"
    assert_match(/^\s+#{ids.fetch(fanned.fetch("key"))} --> #{ids.fetch(continuation)}$/, mermaid,
      "the continuation waits on the tool:\n#{mermaid}")

    printed, status = @daemon.cli("graph", loop_public_id, "--json")
    assert_predicate status, :success?, printed
    graph = JSON.parse(printed)
    assert_equal E2E::ContractFixtures.agent_loops.fetch("graph_envelope"), graph.keys
    assert_includes graph.fetch("edges"), { "from" => "work", "to" => fanned.fetch("key"), "structural" => true }
    assert_includes graph.fetch("edges"), { "from" => fanned.fetch("key"), "to" => continuation, "structural" => true }
    assert_equal %w[work model_task completed visible],
      graph.fetch("nodes").first.values_at("key", "kind", "status", "visibility"),
      "the node speaks the trace's vocabulary: #{graph.fetch("nodes").first.inspect}"
  end

  # AN AGENT, NOT A TOOL ROUND. The journey above proves one call and its
  # answer; this proves the thing that makes it an agent — the model reads
  # a result and decides what to do NEXT, three times, each round's work
  # depending on the last one's answer having come back.
  #
  # It is the shape every long-session feature exists to serve, and until
  # the fake could script a SEQUENCE nothing in this repo could observe
  # it: the deepest reachable loop was model → tool → model, and the
  # multi-round in-process tests are canned frames a test author wrote.
  def test_a_model_works_through_three_rounds_of_tools_on_this_machine
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    workspace_public_id = await_workspace_state("adopted").dig("workspace", "public_id")

    E2E.enable_dev_lane!
    E2E.hosts.start

    marker = SecureRandom.hex(4)
    calls = %w[one two three].map do |word|
      "bash:#{CGI.escape(JSON.generate({ "command" => "echo #{word}-#{marker}" }))}"
    end

    # Through rho's door, as above: rho's agent's loop, its calls
    # addressed to rho's announced address.
    started = @daemon.control(:post, "/loops", body: {
      prompt: "!mock tool_call=#{calls.join(",")} -- work through it",
      model: "dev/mock-text",
    })
    loop_public_id = started.dig("loop", "public_id")
    refute_nil loop_public_id, "rho answered #{started.inspect}"

    completed = await_loop_completion do
      agent_api(:get,
        "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{loop_public_id}")["agent_loop"]
    end
    tasks = completed.fetch("tasks")

    # THREE TOOL TASKS, none of them authored by this journey, each one
    # minted from a call the model made after seeing the previous answer.
    fanned = tasks.select { |task| task.fetch("kind") == "tool_task" }
    assert_equal 3, fanned.length, "the model asked three times: #{tasks.inspect}"
    assert fanned.all? { |task| task.fetch("status") == "completed" },
      "rho ran every one of them"

    outputs = fanned.map do |task|
      agent_api(:get, "/agent_api/v1/workspaces/#{workspace_public_id}" \
        "/agent_loops/#{loop_public_id}/tasks/#{task.fetch("key")}").dig("task", "output").to_s
    end
    %w[one two three].each do |word|
      assert outputs.any? { |out| out.include?("#{word}-#{marker}") },
        "the shell never ran step #{word}: #{outputs.inspect}"
    end

    # AND THE SPINE GREW ONE ROUND PER ANSWER. Four model tasks: three
    # that called, and the one that finally spoke.
    spine = tasks.select { |task| task.fetch("kind") == "model_task" }
    assert_equal 4, spine.length,
      "each answer must have opened a new round: #{spine.map { _1["key"] }.inspect}"
    assert_empty tasks.select { |task| task.fetch("kind") == "join_task" },
      "the kernel's fans wait on every call without a barrier row: an `all` fan draws no join"
  end

  # MEMORY OUTLIVES THE ROUND, AND THE LOOP — which is the whole claim
  # that put it in the kernel instead of on the runner's disk.
  #
  # The model writes a note through a KERNEL tool in round one, reads it
  # back in round two, and then a SECOND loop — a different graph, with
  # its own rounds — finds it still there. Nothing in this journey copies
  # it between them: it is one durable store two loops in one workspace
  # both reach.
  def test_a_model_remembers_across_rounds_and_across_loops
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    workspace_public_id = await_workspace_state("adopted").dig("workspace", "public_id")

    E2E.enable_dev_lane!
    E2E.hosts.start

    secret = "recall-#{SecureRandom.hex(4)}"
    remembered = agent_api(:post,
      "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops",
      body: { agent_loop: { steps: [memory_round(
        "memory_write:#{CGI.escape(JSON.generate(
          { "path" => "workspace/notes.md", "content" => "the secret is #{secret}" }
        ))}," \
        "memory_read:#{CGI.escape(JSON.generate({ "path" => "workspace/notes.md" }))}"
      )], approval_mode: "bypass" } })
    first = remembered.dig("agent_loop", "public_id")
    agent_api(:post,
      "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{first}/start")

    completed = await_loop_completion do
      agent_api(:get,
        "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{first}")["agent_loop"]
    end

    # TWO KERNEL TOOL TASKS, neither authored by this journey: the model
    # asked for both, and the second one only after the first came back.
    memory_tasks = completed.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
    assert_equal %w[memory_read memory_write],
      memory_tasks.map { |t| t.fetch("tool_name") }.sort
    read_back = memory_tasks.find { |t| t.fetch("tool_name") == "memory_read" }
    assert_includes task_output(workspace_public_id, first, read_back.fetch("key")), secret,
      "the round that wrote it is over; this is a different round reading it back"

    # A SECOND LOOP, a different graph entirely, in the same workspace.
    second_loop = agent_api(:post,
      "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops",
      body: { agent_loop: { steps: [memory_round(
        "memory_read:#{CGI.escape(JSON.generate({ "path" => "workspace/notes.md" }))}"
      )], approval_mode: "bypass" } })
    second = second_loop.dig("agent_loop", "public_id")
    agent_api(:post,
      "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{second}/start")

    finished = await_loop_completion do
      agent_api(:get,
        "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{second}")["agent_loop"]
    end
    reader = finished.fetch("tasks").find { |t| t["tool_name"] == "memory_read" }
    refute_nil reader, "the second loop never called memory_read: #{finished.inspect}"
    assert_includes task_output(workspace_public_id, second, reader.fetch("key")), secret,
      "a store that did not outlive its loop would be the runner's disk with extra steps"
  end

  # One model step declaring the kernel memory tools, scripted to call
  # them in sequence.
  #
  # THE DECLARATIONS COME FROM THE CATALOG, not from this file, and that
  # is not tidiness: a task declaring a kernel tool must send
  # BYTE-IDENTICAL bytes or the compile door refuses
  # `kernel_tool_redefined`, because the tools block is the front of every
  # cached prefix. Transcribing them here is exactly the thing no client
  # can get right, which is why the catalog route exists.
  def memory_round(script)
    { model: {
      key: "m1", model: { model: "dev/mock-text" },
      tools: kernel_memory_tools,
      prompt: "!mock tool_call=#{script} -- remember it",
    } }
  end

  def kernel_memory_tools
    @kernel_memory_tools ||= agent_api(:get, "/agent_api/v1/tools")
      .fetch("tools")
      .select { |tool| tool.fetch("canonical_name").start_with?("nexus.memory.") }
      .map { |tool| tool.fetch("definition") }
  end

  def task_output(workspace_public_id, loop_public_id, key)
    agent_api(:get, "/agent_api/v1/workspaces/#{workspace_public_id}" \
      "/agent_loops/#{loop_public_id}/tasks/#{key}").dig("task", "output").to_s
  end

  # The failure has to say what the loop was actually doing, or a stall is
  # indistinguishable from a runner that never woke.
  def await_loop_completion(&probe) = await_loop_status("completed", &probe)

  # THE MEMBER PLANE IS RATE-LIMITED PER CALLER (120 a minute on the loop
  # routes) and every case here reads as the same steward, so a loop poll
  # is paced, never at the daemon's readiness cadence: five reads a second
  # spent the budget in 24 s of a loaded paired round, and every read after
  # answered `rate_limited` — which this helper reported as "last seen nil".
  LOOP_POLL = 1

  def await_loop_status(status, &probe)
    latest = nil
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + E2E::RhoDaemon::READY_TIMEOUT
    loop do
      latest = probe.call
      return latest if latest && latest["status"] == status
      flunk "the loop never reached #{status}; last seen #{latest.inspect}" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep LOOP_POLL
    end
  end

  require_relative "workspace_dedication/protocol_and_store"
  include ProtocolAndStore
end
