require_relative "../test_helper"
require_relative "../support/ops_harness"

# Standalone run authoring and the run listing routes.
class OpsExtensionTest < Minitest::Test
  include RhoTest::OpsHarness

  # Standalone authoring keeps stable guidance before dynamic environment facts,
  # retains the raw system field and admits no conversation-only hooks.
  TOOL_LINES = <<~TEXT.chomp
    You are working on the operator's own machine through these tools:
    - bash: Execute bash commands (ls, grep, find, etc.)
    - code: Run async JavaScript over declared tools and select final output.
    - edit: Make precise file edits with exact text replacement, including multiple disjoint edits in one call
    - find: Find files by glob pattern (respects .gitignore)
    - grep: Search file contents for patterns (respects .gitignore)
    - ls: List directory contents
    - read: Read file contents
    - web_fetch: Fetch a web page by URL
    - write: Create or overwrite files

    Guidelines:
    - Use read to examine files instead of cat or sed.
    - Use write only for new files or complete rewrites.
    - Use edit for precise changes (edits[].oldText must match exactly)
    - When changing multiple separate locations in one file, use one edit call with multiple entries in edits[] instead of multiple edit calls
    - Each edits[].oldText is matched against the original file, not after earlier edits are applied. Do not emit overlapping or nested edits. Merge nearby changes into one edit.
    - Keep edits[].oldText as small as possible while still being unique in the file. Do not pad with large unchanged regions.
    - Pass workdir to bash rather than `cd <dir> && ...`.
    - A server or anything that must outlive the call: start_process, never `&`.
    - Use web_fetch to read a page or a raw file from the web instead of curl or wget in bash; it is a read and returns markdown.
  TEXT

  def test_a_standalone_run_keeps_stable_guidance_first_without_conversation_hooks
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(extensions: [Rho::Runner::Extensions::Coding, Rho::Extensions::Guard, Rho::Extensions::Processes,
      Rho::Extensions::Ops], config: Rho::Config.from_hash({})), api, identity: RUNNER_IDENTITY)

    code, answer = create(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "idempotency_key" => "k-a" })

    assert_equal "201", code, answer.inspect
    authored = api.run_creates.fetch(0)
    assert_equal ["run"], authored.keys
    # THE SHELL: rho names its mode AND its rule list on every standalone run it authors —
    # the kernel refuses nil, nothing is silently defaulted; `bypass` is rho's word by
    # product policy, and a standalone run has its OWN shell, so without the list `rm -rf
    # /` would dispatch to rho's runner where only the floor stands. Nothing names a
    # deliverable.
    assert_equal %w[steps approval_mode approval_rules default_runner_executor_public_id], authored.fetch("run").keys,
      "one model step, the mode and the rules"
    assert_equal Rho::RunDeclaration::APPROVAL_MODE, authored.dig("run", "approval_mode")
    assert_equal "bypass", authored.dig("run", "approval_mode")
    # THE ONE LIST: the daemon's list as it
    # stands — the constant, this install's incubation denies, the session
    # grants (none here) — where the shell once named the bare constant.
    assert_equal Rho::RunDeclaration.approval_rules(roots: Rho.protected_roots(daemon.home)),
      authored.dig("run", "approval_rules"), "the original wire-name policy keeps every clause in place"
    step, *rest = authored.dig("run", "steps")
    assert_empty rest
    assert_equal ["model"], step.keys
    task = step.fetch("model")
    assert_equal %w[prompt key model tools instructions kernel_tools runner_executor_public_ids], task.keys
    assert_equal ["work", "fix it", { "model" => "dev/mock-text" }],
      task.values_at("key", "prompt", "model")
    assert_equal "#{Rho::RunDeclaration::GUIDELINE}\n\nConversation kind: standalone.\n\n#{TOOL_LINES}\n\n" \
                 "Relative paths resolve against #{@root}/work/users/user-1.\nAbsolute paths anywhere on this machine work; nothing is confined.",
      task.fetch("instructions")
    # The selected built-ins and gem supply the exact registry bytes; the
    # full set would also add the todo tracker's agent tool.
    loaded = Rho::Extensions.load(host: RhoTest.host, extensions: [Rho::Runner::Extensions::Coding,
      Rho::Extensions::Processes, Rho::Extensions::Ops], gems: ["rho/codemode", "rho/web-tools"])
    assert_empty loaded.failures
    declared = Rho::RunDeclaration.declaration(registry: loaded.registry, runner_executor_public_ids: ["0199-runner"]).fetch(:tool_definitions)
    assert_equal declared, task.fetch("tools")
    assert_equal 1, task.fetch("tools").count { |entry| entry.dig("function", "name") == "code" },
      "one model declaration even when both executor addresses serve the tool"

    assert_equal ["work"], answer.dig("run", "tasks").map { |row| row.fetch("key") }
    expected_names = %w[bash code edit file_import file_publish find grep list_processes ls read read_process start_process stop_process web_fetch write] +
      %w[code skill].map { |name| NexusDoubles.runner_tool_name("0199-runner", name) }
    assert_equal expected_names.sort, answer.fetch("tools").sort
    refute answer.key?("until")
    refute answer.fetch("run").key?("until"), "no hooks, so no gate"
    assert(api.requests.any? { |path, _| path.end_with?("/runs/al-1/start") })
    assert_equal({}, store.rows.fetch(0).notes)
    assert_equal ["al-1"], JSON.parse(request(daemon, :get, "/followers", token: bearer(daemon)).body)
      .fetch("followers").map { |row| row.fetch("public_id") }
    assert_equal "400", create(daemon, { "prompt" => "p" }).first, "a standalone run names its model"
  end

  # THE ASSEMBLED SHELL: `prompt_mechanism` rides the body to
  # the kernel's shell word for word; under `default`/`assembly` the seed
  # carries NO system field (the kernel refuses `instructions` by name —
  # the guideline is rho's `system_prompt` slot, compiled into the seed by
  # the kernel) and the lead — the environment block and the tool lines,
  # or the caller's words in their place — rides AHEAD of the person's
  # words in the input block, the one text the shell admits. `raw` and an
  # unnamed word keep the bytes above.
  def test_a_standalone_run_under_an_assembled_word_names_the_mechanism_and_leads_the_words
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(extensions: [Rho::Runner::Extensions::Coding, Rho::Extensions::Processes,
      Rho::Extensions::Ops], config: Rho::Config.from_hash({})), api, identity: RUNNER_IDENTITY)
    environment = "Relative paths resolve against #{@root}/work/users/user-1.\n" \
                  "Absolute paths anywhere on this machine work; nothing is confined."

    code, answer = create(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "prompt_mechanism" => "default",
                                    "idempotency_key" => "k-d" })

    assert_equal "201", code, answer.inspect
    authored = api.run_creates.fetch(0).fetch("run")
    assert_equal %w[steps prompt_mechanism approval_mode approval_rules default_runner_executor_public_id], authored.keys
    assert_equal "default", authored.fetch("prompt_mechanism")
    task = authored.fetch("steps").fetch(0).fetch("model")
    assert_equal %w[prompt key model tools kernel_tools runner_executor_public_ids], task.keys, "no system field under an assembled word"
    assert_equal "#{TOOL_LINES}\n\nConversation kind: standalone.\n\nfix it", task.fetch("prompt"),
      "the explicit default template leaves the known kind in the input lead and the guideline in the slot"
    expected_names = %w[bash code edit file_import file_publish find grep list_processes ls read read_process start_process stop_process web_fetch write] +
      %w[code skill].map { |name| NexusDoubles.runner_tool_name("0199-runner", name) }
    assert_equal expected_names.sort, answer.fetch("tools").sort

    create(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "prompt_mechanism" => "assembly",
                     "instructions" => "be terse" })
    task = api.run_creates.fetch(1).dig("run", "steps").fetch(0).fetch("model")
    assert_equal "assembly", api.run_creates.fetch(1).dig("run", "prompt_mechanism")
    assert_equal "be terse\n\nfix it", task.fetch("prompt"),
      "the caller's words in the tool lines' place, as a conversation's lead takes them"
    refute task.key?("instructions")

    create(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "prompt_mechanism" => "raw" })
    task = api.run_creates.fetch(2).dig("run", "steps").fetch(0).fetch("model")
    assert_equal "raw", api.run_creates.fetch(2).dig("run", "prompt_mechanism")
    assert_equal "fix it", task.fetch("prompt")
    assert_equal "#{Rho::RunDeclaration::GUIDELINE}\n\nConversation kind: standalone.\n\n#{TOOL_LINES}\n\n#{environment}", task.fetch("instructions"), "raw keeps the system field"

    create(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "prompt_mechanism" => "default",
                     "instructions" => "my instructions" })
    task = api.run_creates.fetch(3).dig("run", "steps").fetch(0).fetch("model")
    assert_equal "my instructions\n\nConversation kind: standalone.\n\nfix it", task.fetch("prompt"),
      "custom lead instructions keep their place under the explicit default shell"
    refute task.key?("instructions"), "an assembled shell never sends the raw system field"

    refusal = CybrosAgent::Response.new(status: 422, headers: {},
      body: { "error" => { "code" => "prompt_template_missing", "message" => "no template" } })
    api.define_singleton_method(:run_response) do |method, path, credential, body = nil|
      next refusal if method == :post && path.end_with?("/runs")

      super(method, path, credential, body)
    end
    code, answer = create(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "prompt_mechanism" => "assembly" })
    assert_equal "422", code
    assert_equal "prompt_template_missing", answer.dig("error", "code"), "the kernel's shell refusal relays as itself"
  end

  # The standalone author names the runner the same way `rho do` does:
  # under a full boot, this machine's own runner row; the
  # settings' `runner` wins over it; a body's over both; a kernel 422 relays.
  def test_a_standalone_run_names_the_runner_the_host_starts_on
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE,
      executors: [NexusDoubles.remote_runner("0199-named"), NexusDoubles.remote_runner("0199-set"),
                  NexusDoubles.remote_runner("0199-runner", tools: [], root: nil)])
    daemon = boot(device_flow: connection_device_flow, api_transport: api, config: Rho::Config.from_hash({}),
      extensions: [Rho::Runner::Extensions::Coding, Rho::Extensions::Ops])
    token = connect(daemon)
    await_workspace_state(daemon, "adopted", token: token)

    code, answer = create(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })
    assert_equal "201", code, answer.inspect
    assert_equal "0199-runner", api.run_creates.last.dig("run", "default_runner_executor_public_id"),
      "rho's own runner row"
    create(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "default_runner_executor_public_id" => "0199-named" })
    assert_equal "0199-named", api.run_creates.last.dig("run", "default_runner_executor_public_id")

    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE,
      executors: [NexusDoubles.remote_runner("0199-named"), NexusDoubles.remote_runner("0199-set")])
    daemon = member_ready(boot(root: File.join(@root, "set")), api)
    File.write(daemon.home.settings_path, JSON.generate("runner" => "0199-set"))
    create(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })
    assert_equal "0199-set", api.run_creates.last.dig("run", "default_runner_executor_public_id"),
      "the settings' runner, read fresh off the file"

    refusal = CybrosAgent::Response.new(status: 422, headers: {},
      body: { "error" => { "code" => "runner_not_eligible", "message" => "not eligible" } })
    api.define_singleton_method(:run_response) do |method, path, credential, body = nil|
      next refusal if method == :post && path.end_with?("/runs")

      super(method, path, credential, body)
    end
    code, answer = create(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })
    assert_equal "422", code
    assert_equal "runner_not_eligible", answer.dig("error", "code"), "the kernel's refusal, relayed with its code"
  end

  # GROWING A RUN FROM A TERMINAL: the steps go through verbatim and the
  # receipt comes back whole; the phases read is proxied the same way, its
  # background rows as the kernel wrote them: a running tip with no stamp
  # and a delivered one with its `result_delivered_at`, which `rho-dev phases` prints.
  def test_the_append_and_phases_routes_proxy_the_run_door_and_the_derived_read
    phases = { "phases" => [{ "label" => "work", "keys" => ["work"], "done" => 1, "total" => 1,
                              "status" => "completed" }],
               "current" => nil,
               "background" => [{ "key" => "r1t0-model-1", "status" => "running" },
                                { "key" => "r1t0-model-2", "status" => "completed",
                                  "result_delivered_at" => "2026-09-06T00:00:09.000Z" }],
               "spend" => { "input_tokens" => 2 } }
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, phases: phases)
    daemon = member_ready(boot, api)
    steps = [{ "ask" => { "key" => "gate", "prompt" => "ok?" } }, { "model" => { "key" => "more", "prompt" => "go" } }]

    response = request(daemon, :post, "/runs/append", token: bearer(daemon),
      body: { public_id: "al-9", steps: steps, resolve: [{ "task" => "check-1" }], idempotency_key: "k-1" })
    assert_equal "201", response.code, response.body
    receipt = JSON.parse(response.body).fetch("receipt")
    assert_equal %w[gate more], receipt.fetch("accepted_task_keys")
    assert_equal "more", receipt.fetch("deliverable_task_key")
    sent = api.appends.fetch(0)
    assert_equal steps, sent.fetch("steps"), "the steps reach the door verbatim"
    assert_equal [{ "task" => "check-1" }], sent.fetch("resolve")
    refute sent.key?("deliverable")

    malformed = request(daemon, :post, "/runs/append", token: bearer(daemon),
      body: { public_id: "al-9", steps: "nope" })
    assert_equal "400", malformed.code

    read = request(daemon, :get, "/runs/phases?public_id=al-9", token: bearer(daemon))
    assert_equal "200", read.code, read.body
    assert_equal phases, JSON.parse(read.body).fetch("phases")
    assert_equal "400", request(daemon, :get, "/runs/phases", token: bearer(daemon)).code
  end

  def test_the_runs_route_answers_the_followers_by_default_and_the_server_on_request
    trace_row = {
      "public_id" => "al-9", "status" => "running",
      "attention" => { "reason" => "halt_failure" },
      "created_at" => "2026-09-04T00:00:00Z",
    }
    api = NexusDoubles::FakeAgentApi.new(run_list: [trace_row])
    daemon = member_ready(boot, api)

    local = JSON.parse(request(daemon, :get, "/followers", token: bearer(daemon)).body)
    assert_equal [], local.fetch("followers"), "this daemon follows nothing yet"

    served = JSON.parse(
      request(daemon, :get, "/runs?attention=any", token: bearer(daemon)).body
    )
    row = served.fetch("runs").fetch(0)
    assert_equal "al-9", row.fetch("public_id")
    assert_equal "halt_failure", row.dig("attention", "reason")
    refute row.fetch("followed"), "the person needs to know before typing `rho watch`"
    assert(api.requests.any? { |_path, _credential, params| params&.dig("attention") == "any" },
      "the filter reached the kernel: #{api.requests.map(&:last).inspect}")
  end

  # A followed CONVERSATION counts as every run it backed: the server
  # listing marks the current one and the earlier ones followed.
  def test_the_server_listing_marks_every_run_a_followed_conversation_backed
    rows = %w[al-1 al-2 al-3].map do |id|
      { "public_id" => id, "status" => "completed", "created_at" => "2026-09-04T00:00:00Z" }
    end
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(run_list: rows))
    run = fake_run("c-1", host: true)
    run.define_singleton_method(:backs?) { |id| %w[c-1 al-1 al-2].include?(id) }
    daemon.lineage.install_follower(daemon.lineage.credentials, run)

    served = JSON.parse(request(daemon, :get, "/runs", token: bearer(daemon)).body)

    assert_equal [true, true, false], served.fetch("runs").map { |row| row.fetch("followed") }
  end

  # A STANDALONE RUN ON A RUNNER ELSEWHERE: the seed carries
  # that runner's announced entries — this machine's tools would fail
  # `tool_not_served` there — with the announced snapshot as its
  # instructions, the kernel's after; the `tools:` line says what the seed
  # carried, and the row remembers the binding.
  def test_a_standalone_run_on_a_remote_runner_carries_the_runners_entries_on_its_seed
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, tools: NexusDoubles::KERNEL_CATALOG,
      executors: [NexusDoubles.remote_runner("0199-h")])
    daemon = member_ready(boot(extensions: [Rho::Runner::Extensions::Coding, Rho::Extensions::Ops],
      config: Rho::Config.from_hash({ "kernel_tools" => NexusDoubles::KERNEL_TOOLS.keys })), api, identity: RUNNER_IDENTITY)

    code, answer = create(daemon, { "prompt" => "read it", "model" => "dev/mock-text",
                                    "default_runner_executor_public_id" => "0199-h" })

    assert_equal "201", code, answer.inspect
    task = api.run_creates.fetch(0).dig("run", "steps", 0, "model")
    assert_equal ["code"], task.fetch("tools").map { |entry| entry.dig("function", "name") }
    assert_equal ["nexus.graph.delegate_task"], task.fetch("kernel_tools")
    assert_equal %w[0199-h 0199-runner], task.fetch("runner_executor_public_ids")
    refute task.fetch("tools").any? { |entry| entry.key?("route") }, "Nexus owns Runner schema import"
    expected_names = %w[code delegate_task slow_read slow_write]
    assert_equal "#{Rho::RunDeclaration::GUIDELINE}\n\nConversation kind: standalone.\n\nRelative paths resolve against /srv/elsewhere.", task.fetch("instructions")
    assert_equal "0199-h", api.run_creates.fetch(0).dig("run", "default_runner_executor_public_id")
    assert_equal expected_names.sort, answer.fetch("tools").sort
    assert_equal "0199-h", store.find("al-1").runner
    assert_empty api.configuration_declarations, "a seed carries its own tools: nothing to declare"
  end

  def test_a_standalone_remote_run_uses_the_current_candidate_document_without_a_cached_lookup
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE,
      executors: [NexusDoubles.remote_runner("0199-h", root: "/srv/current")])
    api.define_singleton_method(:executor_response) do |method, path, credential|
      if path.end_with?("/executors/0199-h")
        next respond(503, { "error" => { "code" => "unavailable", "message" => "discovery unavailable" } })
      end

      super(method, path, credential)
    end
    daemon = member_ready(boot(extensions: [Rho::Runner::Extensions::Coding, Rho::Extensions::Ops],
      config: Rho::Config.from_hash({})), api, identity: RUNNER_IDENTITY)

    code, answer = create(daemon, { "prompt" => "read it", "model" => "dev/mock-text",
                                    "default_runner_executor_public_id" => "0199-h" })

    assert_equal "201", code, answer.inspect
    instructions = api.run_creates.last.dig("run", "steps", 0, "model", "instructions")
    assert_includes instructions, "Relative paths resolve against /srv/current."
    refute_includes instructions, daemon.context.tool_env.root
    refute_includes instructions, "You are working on the operator's own machine"
    assert_equal "/srv/current", daemon.context.remote_runner("0199-h").environment.fetch("root")
  end

  def test_a_standalone_code_mode_filter_uses_fresh_selected_runner_tools
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE,
      executors: [NexusDoubles.remote_runner("0199-h", tools: %w[old_read code].map { |name| NexusDoubles.served_tool(name) })])
    daemon = member_ready(boot, api)
    assert_equal %w[old_read code], daemon.context.remote_runner("0199-h").served_tools.map(&:name)
    api.remove_executor("0199-h")
    api.stock_runner_unless_present("0199-h", tools: %w[new_read code].map { |name| NexusDoubles.served_tool(name) })

    code, answer = create(daemon, { "prompt" => "read it", "model" => "dev/mock-text", "code_mode" => false,
                                    "default_runner_executor_public_id" => "0199-h" })

    assert_equal "201", code, answer.inspect
    task = api.run_creates.last.dig("run", "steps", 0, "model")
    assert_equal ["new_read"], task.fetch("runner_tool_names")
    assert_equal ["new_read"], answer.fetch("tools")
    assert_equal %w[new_read code], daemon.context.remote_runner("0199-h").served_tools.map(&:name)
  end
end
