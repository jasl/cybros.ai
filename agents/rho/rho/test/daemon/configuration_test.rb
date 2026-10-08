require "test_helper"
require "support/nexus_doubles"
require "support/daemon_harness"

# The profile's standing declaration, written on the
# workspace-adopted edge — boot; a `rho env` repoint rebuilds the runner and
# re-announces, and declares nothing again (the declaration reads the registry, not the root). The kernel derives no tool list of its
# own, so an undeclared daemon runs turns toolless.
class DaemonConfigurationTest < Minitest::Test
  include RhoTest::DaemonHarness

  # The flat verbs and memory verbs are fetched by canonical name.
  FLAT = { "nexus.graph.delegate_task" => "delegate_task", "nexus.human.ask" => "ask" }.map do |canonical, name|
    { "canonical_name" => canonical, "name" => name, "effect_profile" => {},
      "definition" => { "type" => "function",
                        "function" => { "name" => name, "description" => "the #{name} verb",
                                        "parameters" => { "type" => "object", "properties" => {} } } } }
  end.freeze
  MEMORY = %w[read write edit ls grep delete].map do |verb|
    { "canonical_name" => "nexus.memory.#{verb}", "name" => "memory_#{verb}", "effect_profile" => {},
      "definition" => { "type" => "function",
                        "function" => { "name" => "memory_#{verb}", "description" => "memory #{verb}",
                                        "parameters" => { "type" => "object", "properties" => {} } } } }
  end.freeze
  # Conversation work and history reads are declared by default; the
  # history tools retain their conventional session names on the wire.
  CONVERSATION = { "spawn" => "spawn", "send" => "send", "status" => "status", "cancel" => "cancel",
                   "search" => "session_search", "read" => "session_read" }.map do |verb, name|
    { "canonical_name" => "nexus.conversation.#{verb}", "name" => name, "effect_profile" => {},
      "definition" => { "type" => "function",
                        "function" => { "name" => name, "description" => "conversation #{verb}",
                                        "parameters" => { "type" => "object", "properties" => {} } } } }
  end.freeze
  # The `skill` load, declared by default: the
  # kernel's one source-routed tool, which the `claude` preset spells `Skill`.
  SKILL = { "canonical_name" => "nexus.skill.load", "name" => "skill", "effect_profile" => {},
            "definition" => { "type" => "function",
                              "function" => { "name" => "skill", "description" => "the skill load",
                                              "parameters" => { "type" => "object", "properties" => {} } } } }.freeze
  DISCOVERY = { "search" => "tool_search", "call" => "tool_call" }.map do |verb, name|
    { "canonical_name" => "nexus.tools.#{verb}", "name" => name, "effect_profile" => {},
      "definition" => { "type" => "function",
                        "function" => { "name" => name, "description" => "tool #{verb}",
                                        "parameters" => { "type" => "object", "properties" => {} } } } }
  end.freeze
  RUNNERS = { "canonical_name" => "nexus.runners.list", "name" => "runners_list", "effect_profile" => {},
              "definition" => { "type" => "function", "function" => { "name" => "runners_list",
                "description" => "List candidate environments", "parameters" => { "type" => "object", "properties" => {} } } } }.freeze
  CATALOG = [*FLAT, *MEMORY, *CONVERSATION, SKILL, *DISCOVERY, RUNNERS].freeze
  WORKSPACE = { public_id: "0199-workspace", name: "Helper", dedicated: true }.freeze

  def adopted(api, **options)
    daemon = boot(device_flow: connection_device_flow, api_transport: api, **options)
    token = connect(daemon)
    await_workspace_state(daemon, "adopted", token: token)
    [daemon, token]
  end

  def declared(api, count = 1)
    wait_for { api.configuration_declarations.length >= count }
    api.configuration_declarations.fetch(count - 1).fetch("configuration")
  end

  # The RUNNER address's announcement: the environment tools and
  # the root's document, under the runner's credential.
  def announced(api, count = 1)
    wait_for { api.runner_announcements.length >= count }
    api.runner_announcements.fetch(count - 1).fetch("tools")
  end

  def announced_environment(api, count = 1)
    wait_for { api.runner_announcements.length >= count }
    api.runner_announcements.fetch(count - 1).fetch("environment")
  end

  # The runner address's third list: the root's
  # skills, announced beside the tools and the environment document.
  def announced_documents(api, count = 1)
    wait_for { api.runner_announcements.length >= count }
    api.runner_announcements.fetch(count - 1).fetch("documents")
  end

  # The AGENT address's own: the delegate summarizer, no environment.
  def agent_announced(api, count = 1)
    wait_for { api.announcements.length >= count }
    api.announcements.fetch(count - 1)
  end

  def runner_document(daemon, token)
    JSON.parse(request(daemon, :get, "/runner", token: token).body).fetch("runner")
  end

  # `/status`'s own runner block — the daemon's meters, not the slot's.
  def status_runner(daemon, token)
    JSON.parse(request(daemon, :get, "/status", token: token).body).fetch("runner")
  end

  def test_configure_redeclares_new_settings_and_tools_without_forgetting_hosts
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    daemon, = adopted(api)
    original = declared(api)
    host = Rho::Host::Conversation.new("kept-conversation")
    host_store(daemon).remember(host, workspace: WORKSPACE.fetch(:public_id))
    config = Rho::Config.from_hash({ "default_model" => "dev/new-model", "fallback_model" => "dev/fallback",
      "kernel_tools" => ["nexus.graph.delegate_task"], "adaptations" => "off",
      "plugins" => { "rho.compaction" => { "configuration_version" => 1, "configuration" => { "mode" => "kernel", "model" => "dev/summary" } } } })
    loaded = Rho::Extensions.load(host: daemon.host, extensions: [])

    outcome = Async { daemon.host_followers.configure(config: config, loaded: loaded) }.wait

    assert_equal :declared, outcome
    latest = declared(api, 2)
    assert_equal "dev/new-model", latest.fetch("default_model")
    assert_equal "dev/fallback", latest.fetch("fallback_model")
    assert_equal({ "mode" => "off" }, latest.fetch("compaction_policy"), "removing the compaction plugin disables its policy")
    assert_empty latest.fetch("tool_definitions")
    assert_equal ["nexus.graph.delegate_task"], latest.fetch("kernel_tools")
    assert_includes original.fetch("runner_executor_public_ids"), "0199-runner"
    assert_predicate daemon.host_followers.adaptations, :off?
    assert_equal WORKSPACE.fetch(:public_id), host_store(daemon).find(host.public_id).workspace
    assert_equal :unchanged, Async { daemon.host_followers.configure(config: config, loaded: loaded) }.wait
    assert_equal 2, api.configuration_declarations.length
  end

  # THE TWO ANNOUNCEMENTS: what each ADDRESS
  # serves, written on the executor plane before its runner follows and
  # before the profile is declared — the kernel addresses a call by it,
  # and a runner that followed before its address announced would meet
  # `tool_not_served` on the first call. The runner address: this
  # machine's environment tools alone, each with exactly the five effect
  # keys and the declaration facts, beside the root's
  # environment document. The agent address: the agent's own (the delegate
  # summarizer), no environment.
  def test_each_address_announces_what_it_serves_before_the_profile_is_declared
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    daemon, token = adopted(api)
    declared(api)

    tools = announced(api)
    # Re-cut with the work-root exemption: a default-layout home opens a
    # checkpoint store for its placed runner, so the store's two hidden
    # names (`checkpoints`, `checkpoint_restore`) announce beside the coding set.
    assert_equal %w[bash checkpoint_restore checkpoints code edit environment_bind file_import file_publish files_bytes find grep list_processes ls process_log read
                    read_process skill start_process stop_process web_fetch write],
      tools.map { |entry| entry.fetch("name") }, "the runner address: this machine's tools, never the kernel's"
    tools.each do |entry|
      assert_equal %w[kind destructive effect_scope idempotency reconciliation], entry.fetch("effect_profile").keys
      # The person's two reads, the kernel's skill load and the store's two
      # announce described to nobody (`checkpoint_restore` carries its park alone).
      if %w[files_bytes process_log checkpoints checkpoint_restore environment_bind].include?(entry.fetch("name"))
        expected = entry.fetch("name") == "checkpoint_restore" ? %w[effect_profile name timeout_ms] : %w[effect_profile name]
        assert_equal expected, entry.keys.sort
        next
      end

      expected = %w[name effect_profile description input_schema]
      expected << "timeout_ms" if entry.fetch("name") == "web_fetch"
      assert_equal expected.sort, entry.keys.sort
      assert_equal 60_000, entry.fetch("timeout_ms") if entry.fetch("name") == "web_fetch"
      assert_equal "object", entry.fetch("input_schema").fetch("type")
      refute_empty entry.fetch("description")
    end
    environment = announced_environment(api)
    configured = JSON.parse(request(daemon, :get, "/environment", token: token).body).dig("environment", "root")
    assert_equal configured, environment.fetch("root"), "the daemon's root, announced beside the list"
    assert_includes environment.fetch("fragments").map { |fragment| fragment.fetch("extension") }, "rho.coding"
    refute environment.key?("working_directory"), "the announced document is the root's"

    # THE PER-TOOL TIMEOUTS: the delegate summarizer parks
    # two minutes so a dead rho's cost is bounded to the fallback, the todo
    # tracker thirty seconds — on the AGENT address,
    # with no environment document beside it.
    agent = agent_announced(api)
    assert_equal [["code", nil], ["list_extensions", nil], ["manage_extension", 120_000],
                  ["manage_schedule", 30_000], ["read_schedules", 30_000],
                  ["summarize_history", 120_000], ["todo_write", 30_000]],
      agent.fetch("tools").map { |entry| entry.values_at("name", "timeout_ms") }
    agent.fetch("tools").each do |entry|
      keys = %w[name effect_profile description input_schema]
      keys << "timeout_ms" unless %w[code list_extensions].include?(entry.fetch("name"))
      assert_equal keys.sort, entry.keys.sort
    end
    refute agent.key?("environment"), "the environment document is the runner address's"

    paths = api.requests.map(&:first)
    assert_operator paths.index("/agent_api/v1/executor/announcement"), :<,
      paths.index("/agent_api/v1/profile/configuration"), "the announcements land before the declaration"
    document = JSON.parse(request(daemon, :get, "/runner", token: token).body)
    assert_equal tools.length, document.fetch("runner").fetch("announced"), "the snapshot says what the runner address announced"
    assert_equal 7, document.fetch("agent").fetch("announced")
    assert_equal %w[summarize_history todo_write read_schedules manage_schedule list_extensions manage_extension code], document.fetch("agent").fetch("tools")
  end

  # `rho env` rebuilds the runners on the new root through the same site, so
  # each address's announcement is written again beside the declaration.
  # THE DOCUMENTS RIDE EACH ADDRESS'S ANNOUNCEMENT: the root's `SKILL.md` files as `{name,
  # description}`, beside the tools and the environment document, on the
  # runner address — and the agent address's own projection, which here
  # (no extension announcing documents there) is the empty list, never an
  # omitted key: what the address serves now, so a list once announced is
  # withdrawn by the next announcement rather than kept.
  def test_the_runner_announcement_carries_the_roots_skills_as_documents
    root = File.join(@root, "checkout")
    dir = File.join(root, ".agents", "skills", "deploy-notes")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"),
      "---\nname: deploy-notes\ndescription: How this project is deployed.\n---\n# Deploy\n", encoding: "UTF-8")
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    adopted(api, config: Rho::Config.from_hash({ "tools_root" => root }))

    assert_equal [{ "name" => "deploy-notes", "description" => "How this project is deployed." }], announced_documents(api)
    assert_includes announced(api).map { |entry| entry.fetch("name") }, "skill",
      "an address announcing documents announces skill, the tool the kernel delivers a load to"
    assert_equal %w[name effect_profile description input_schema], announced(api).find { |entry| entry.fetch("name") == "skill" }.keys,
      "an explicit Runner source carries its exact schema"
    wait_for { api.announcements.length >= 1 }
    assert_equal [], api.announcements.first.fetch("documents"), "the agent address announces its own projection: none"
    refute api.announcements.first.key?("environment"), "the environment document is the runner address's"
  end

  # THE RUNNER ADDRESS ALONE: the
  # environment document is the runner address's, so `rho env` writes that
  # one again; the agent's own carries no environment and is not rewritten.
  def test_repointing_the_tools_announces_again
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: FLAT)
    daemon, token = adopted(api)
    announced(api)
    agent_announced(api)
    root = File.join(@root, "elsewhere")
    FileUtils.mkdir_p(root)

    response = request(daemon, :post, "/environment", token: token, body: { "root" => root })

    assert_equal "200", response.code, response.body
    assert_equal announced(api, 1), announced(api, 2), "the same announcement, written again"
    assert_equal File.realpath(root), File.realpath(api.runner_announcements.last.dig("environment", "root")),
      "on the new root"
    assert_equal 1, api.announcements.length, "the agent's own carries no environment: not rewritten"
  end

  # A refusal costs the announcement and is written down; the runner still
  # runs, the declaration still lands, and the snapshot says nothing was
  # announced — which is why the first call reads `tool_not_served`.
  def test_a_refused_announcement_is_logged_and_the_runner_still_runs
    refusal = CybrosAgent::Response.new(
      status: 422, headers: {},
      body: { "error" => { "code" => "reserved_tool_name", "message" => "no" } }
    )
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], announcement: refusal)
    daemon, token = adopted(api)
    declared(api)

    wait_for do
      File.read(daemon.home.log_path, encoding: Encoding::UTF_8).include?("executor.announcement_failed")
    end
    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    assert_includes log, "reserved_tool_name"
    runner = runner_document(daemon, token)
    assert runner.fetch("running"), "a refused announcement is not a reason to stop taking work"
    assert_nil runner.fetch("announced")
  end

  # A RUNNER WITHOUT A TRANSPORT CREDENTIAL CANNOT WORK: the
  # inbox, the claim and the commit are all the executor plane's. A lineage
  # that holds only the member half places no runner on either address — a
  # dark one would only log sweep failures — gives its reservations back,
  # and says so. The ceremony refuses a member-only branch at the door, so
  # the lineage is a fixture adopted through the lineage's own verbs, the
  # way `inference_request_ready` builds one, and the placement seam is driven directly.
  def test_a_lineage_with_no_transport_credential_at_all_places_nothing_and_says_so
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    daemon = member_ready(boot, api)
    about = daemon.lineage.credentials
    about.define_singleton_method(:executor_credential) do
      raise CybrosAgent::Credentials::PlaneUnavailable, "this connection has no live executor_transport credential"
    end

    daemon.send(:place_runners, about, NexusDoubles::MEMBER_TOKEN, "ws-1")

    assert_empty daemon.lineage.runners
    assert_equal({ runner: nil, agent: nil }, daemon.context.runner_snapshot, "no runner: the honest answer, not an idle shape")
    assert daemon.lineage.reserve_runner(about), "the runner reservation was given back"
    assert daemon.lineage.reserve_runner(about, slot: :agent_runner), "and the agent's"
    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    assert_includes log, "runner.not_placed slot=runner reason=\"runner plane unavailable\""
    assert_includes log, "runner.not_placed slot=agent_runner reason=\"agent plane unavailable\""
    assert_empty api.announcements, "nothing to announce from"
    assert_empty api.runner_announcements
    refute(api.requests.any? { |path, _| (path == "/agent_api/v1/executor" || path.start_with?("/agent_api/v1/executor/")) },
      "the executor plane is never touched without its credential")
    assert_nil daemon.lineage.executor_realtime
  end

  # A lineage with the agent's transport credential and no runner lineage
  # (agent mode, or a full home whose runner is gone): the agent's own run
  # is placed, the runner slot says why it is not.
  def test_a_lineage_with_no_runner_credential_places_the_agents_run_alone
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    daemon = member_ready(boot, api)
    about = daemon.lineage.credentials
    about.define_singleton_method(:executor_credential) { NexusDoubles::TRANSPORT_TOKEN }
    about.define_singleton_method(:agent) { self }

    daemon.send(:place_runners, about, NexusDoubles::MEMBER_TOKEN, "ws-1")

    assert_nil daemon.lineage.runner(:runner)
    refute_nil daemon.lineage.runner(:agent_runner)
    assert_equal %w[summarize_history todo_write read_schedules manage_schedule list_extensions manage_extension code], daemon.context.runner_snapshot.fetch(:agent).fetch(:tools)
    assert_nil daemon.context.runner_snapshot.fetch(:runner)
    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    assert_includes log, "runner.not_placed slot=runner"
    assert_equal 1, api.announcements.length, "the agent address announced its own"
    assert_empty api.runner_announcements
  end

  def test_the_profile_is_declared_whole_when_a_workspace_is_adopted
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    daemon, = adopted(api)

    configuration = declared(api)
    names = configuration.fetch("tool_definitions").map { |entry| entry.dig("function", "name") }
    assert_equal %w[code list_extensions manage_extension manage_schedule read_schedules skill todo_write], names
    assert_equal CATALOG.map { |entry| entry.fetch("canonical_name") }, configuration.fetch("kernel_tools")
    assert_equal ["0199-runner"], configuration.fetch("runner_executor_public_ids")
    assert_nil configuration.fetch("runner_tool_names")
    refute configuration.fetch("tool_definitions").any? { |entry| entry.key?("route") },
      "Runner schemas and routes belong to Nexus assembly"
    assembled = daemon.context.member_plane(require_workspace: false) do |client, *|
      client.tools.assemble(default_runner_executor_public_id: "0199-runner").tool_definitions
    end
    assert_equal FLAT.first.fetch("definition"), assembled.find { |entry| entry.dig("function", "name") == "delegate_task" },
      "rho consumes the kernel's exact projected schema"
    assert_includes assembled.map { |entry| entry.dig("function", "name") }, "bash"
    discovery = assembled.select { |entry| %w[tool_search tool_call].include?(entry.dig("function", "name")) }
    assert discovery.none? { |entry| entry["defer_loading"] }, "the stable discovery and invocation pair stays visible"
    assert_equal Rho::RunDeclaration::APPROVAL_MODE, configuration.fetch("approval_mode")
    rules = Rho::RunDeclaration.approval_rules(roots: Rho.protected_roots(daemon.home))
    assert_equal rules, configuration.fetch("approval_rules"), "every wire-name policy clause keeps its position"
    assert_equal Rho::RunDeclaration::PROMPT_MECHANISM, configuration.fetch("prompt_mechanism")
    assert_equal Rho::RunDeclaration::PROMPT_TEMPLATE, configuration.fetch("prompt_template")
    assert_equal({ "mode" => "kernel" }, configuration.fetch("compaction_policy"),
      "the kernel's summarizer is the shipped default")
    assert_nil configuration.fetch("default_model"), "no default_model in the settings: the profile declares none"
    refute_includes names, "summarize_history",
      "the delegate is addressed by the profile's policy NAME, never offered to a model"
  end

  # THE PROFILE FACT: rho's own `default_model` is
  # written to the profile at the declaration edge — the application
  # decides, the kernel stores a fact — so every turn another agent
  # addresses to rho runs on it before the initiator's model.
  def test_the_declaration_carries_the_settings_default_model_as_the_profiles_own
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    adopted(api, config: Rho::Config.from_hash({ "default_model" => "openrouter/own" }))

    assert_equal "openrouter/own", declared(api).fetch("default_model")
  end

  # THE FALLBACK ON REFUSAL OR OVERLOAD rides the same declaration beside
  # `default_model` — the model the kernel re-runs a step rho answers on
  # once when a provider's classifier declined it — and `GET /status`
  # carries both back as the kernel answered the declaration, the read a
  # person has of what the settings stand for. Before any declaration the
  # block is absent; with none set, both are null.
  def test_the_declaration_carries_the_fallback_model_and_the_status_reads_both_back
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    daemon, token = adopted(api, config: Rho::Config.from_hash({ "default_model" => "openrouter/own",
      "fallback_model" => "dev/fallback" }))

    assert_equal "dev/fallback", declared(api).fetch("fallback_model")
    profile = nil
    wait_for { profile = JSON.parse(request(daemon, :get, "/status", token: token).body)["profile"] }
    assert_equal({ "default_model" => "openrouter/own", "fallback_model" => "dev/fallback" }, profile)
  end

  def test_no_fallback_in_the_settings_declares_none_and_the_status_says_so
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    daemon, token = adopted(api)

    assert_nil declared(api).fetch("fallback_model"), "no fallback_model in the settings: the profile declares none"
    profile = nil
    wait_for { profile = JSON.parse(request(daemon, :get, "/status", token: token).body)["profile"] }
    assert_equal({ "default_model" => nil, "fallback_model" => nil }, profile)
  end

  # THE SELF-MODIFICATION DENIES: the declaration's rules deny `write|edit` under, and a
  # command naming, the checkout the running daemon loads from (`Rho.root`, the runner
  # gem's root when it sits elsewhere) and this home's MEMBERS — each resolved — with the
  # incubation sentence. Rho's own rules through the kernel's mechanism; nothing
  # kernel-side knows what rho is. THE HOME IS ENUMERATED: every entry of the layout
  # except the work root (`Home#protected_members`) rides its own deny — a shape a kernel
  # glob can express — and the work root, which the default environment root sits under,
  # is simply not in the list; so the kernel refuses `<home>/settings.json` and every
  # credential file BEFORE ANY RUNNER, and passes the model's own project by absolute
  # path.
  def test_the_declaration_carries_the_self_modification_denies_for_the_program_roots_and_the_homes_members
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    daemon, = adopted(api)

    rules = declared(api).fetch("approval_rules")
    denies = rules.select { |rule| rule["reason"] == Rho::RunDeclaration::INCUBATION }
    home = daemon.home
    roots = Rho.protected_roots(home)
    assert_includes roots, File.realpath(Rho.root)
    assert_equal File.join(home.root, "work"), home.work_root, "the default layout"
    refute_includes roots, File.realpath(home.root), "the home's own entry is never a root: its members are"
    refute_includes roots, Rho.spelled(home.work_root), "the work root is not in the list"
    home.protected_members.each { |member| assert_includes roots, Rho.spelled(member), member }
    assert_equal roots.uniq, roots
    assert_equal roots.length * 3, denies.length
    # THE KERNEL'S READING of the declared rules (`Executors::Rules::Glob`:
    # `*` any text, `?` one character, anchored, no escape): the home's
    # settings, the identity's vault and an MCP credential are each
    # denied by an edit rule and by a command rule naming them; the
    # identity's project under the work root is denied by none.
    edits = denies.select { |rule| rule["tool"] == Rho::RunDeclaration::EDIT_TOOLS }
    commands = denies.select { |rule| rule["tool"] == Rho::RunDeclaration::GUARDED_TOOLS }
    denied = ->(rules, text) { rules.any? { |rule| File.fnmatch?(rule["match"], text, File::FNM_NOESCAPE) } }
    [home.settings_path, File.join(home.identity_root("u1"), "credentials.json"),
     File.join(home.mcp_credentials_dir, "fx.json")].each do |secret|
      assert denied.call(edits, Rho.spelled(secret)), "a write to #{secret} is denied by the declared rules"
      assert denied.call(commands, "echo x >> #{Rho.spelled(secret)}"), "a command naming #{secret} is denied"
    end
    project = File.join(Rho.spelled(home.identity_work_root("u1")), "proj", "x.rb")
    refute denied.call(edits, project), "the identity's project by absolute path is denied by no rule"
    refute denied.call(commands, "ls #{project}"), "a command naming the project is denied by no rule"
    roots.each do |root|
      assert_includes denies, { "tool" => "write|edit", "path" => "path", "match" => root,
                                "verdict" => "deny", "reason" => Rho::RunDeclaration::INCUBATION }
      assert_includes denies, { "tool" => "write|edit", "path" => "path", "match" => "#{root}/*",
                                "verdict" => "deny", "reason" => Rho::RunDeclaration::INCUBATION }
      assert_includes denies, { "tool" => Rho::RunDeclaration::GUARDED_TOOLS, "path" => "command", "match" => "*#{root}*",
                                "verdict" => "deny", "reason" => Rho::RunDeclaration::INCUBATION }
    end
    assert File.file?(File.join(Rho.root, "lib", "rho.rb")) && File.file?(File.join(Rho.root, "rho.gemspec")),
      "the checkout the running process loads `lib/rho.rb` from: #{Rho.root}"
    assert File.file?(File.join(Rho::Runner.root, "lib", "rho", "runner.rb")), Rho::Runner.root
  end

  # THE BOOT ROW IS THE UNIVERSE:
  # under `adaptations: claude` — the SDK pack's claude row, pinned — the
  # boot declaration carries the preset's alias entries `Agent`,
  # `AskUserQuestion` and `Skill` in the SDK helper's compact shape beside
  # the memory verbs, and no plain `task`/`ask`/`skill`; the
  # `Agent` recut is rendered against the template the kernel SERVED on
  # `GET /tools` (the fake serves one for `task`), never a copied text;
  # the kernel renders and validates the set (3-1). The log says which
  # row the boot runs under.
  def test_under_the_claude_row_the_declaration_carries_the_presets_aliases_and_no_plain_task_or_ask
    pack = CybrosAgent::ModelAdaptations.load
    claude = pack.presets.preset("claude").aliases
    anchor = claude.first.dig("recut", "anchor")
    served = CATALOG.map do |row|
      row.fetch("canonical_name") == "nexus.graph.delegate_task" ? row.merge("template" => "The task verb.\n\n#{anchor}") : row
    end
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: served)
    logged = StringIO.new
    adopted(api, config: Rho::Config.from_hash({ "adaptations" => "claude" }), log: Rho::Log.new(io: logged))

    definitions = declared(api).fetch("tool_definitions")
    names = definitions.map { |entry| entry.dig("function", "name") }
    assert_equal %w[Agent AskUserQuestion Skill code list_extensions manage_extension manage_schedule read_schedules todo_write], names
    assert_equal CATALOG.map { |entry| entry.fetch("canonical_name") } -
      %w[nexus.graph.delegate_task nexus.human.ask nexus.skill.load], declared(api).fetch("kernel_tools"),
      "the alias styles suppress only their superseded plain exports"
    refute_includes names, "delegate_task"
    refute_includes names, "ask"
    refute_includes names, "skill"
    skill = claude.find { |spec| spec.fetch("name") == "Skill" }
    assert_equal({ "type" => "function", "function" => { "name" => "Skill" }, "canonical" => "nexus.skill.load",
                   "params" => skill.fetch("params"), "defer_loading" => true },
      definitions.find { |entry| entry.dig("function", "name") == "Skill" })
    agent = definitions.find { |entry| entry.dig("function", "name") == "Agent" }
    assert_equal %w[type function canonical params description], agent.keys
    assert_equal "nexus.graph.delegate_task", agent.fetch("canonical")
    assert_equal claude.first.dig("params", "run_in_background"), agent.dig("params", "run_in_background")
    assert_equal "The task verb.\n\n#{claude.first.dig("recut", "replacement")}", agent.fetch("description"),
      "the served template with the one anchored edit — the pack copies no kernel text"
    assert_equal({ "type" => "function", "function" => { "name" => "AskUserQuestion" }, "canonical" => "nexus.human.ask" },
      definitions.find { |entry| entry.dig("function", "name") == "AskUserQuestion" })
    wait_for { logged.string.include?("event=adaptations.boot_row") }
    assert_includes logged.string, "event=adaptations.boot_row row=claude source=gem"
  end

  # A MOVED ANCHOR REFUSES THE DECLARATION, LOUD: a kernel
  # whose `task` template no longer carries the recut's paragraph — here
  # a fake serving another text — leaves the profile UNDECLARED under the
  # pinned row, the log naming the entry; never a silent fallback to the
  # plain text.
  def test_a_moved_anchor_refuses_the_declaration_by_the_entrys_name
    served = CATALOG.map do |row|
      row.fetch("canonical_name") == "nexus.graph.delegate_task" ? row.merge("template" => "The task verb, re-cut.") : row
    end
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: served)
    logged = StringIO.new
    adopted(api, config: Rho::Config.from_hash({ "adaptations" => "claude" }), log: Rho::Log.new(io: logged))

    wait_for { logged.string.include?("event=adaptations.anchor_moved") }
    assert_match(/level=error event=adaptations\.anchor_moved row=claude error="Agent: the anchor moved; re-cut the entry/, logged.string)
    assert_empty api.configuration_declarations, "no declaration under a row whose recut cannot render"
  end

  # THE DELEGATE FLAG: under `compaction: delegate` the
  # profile declares rho's own summarizer by name — the arm addresses the
  # delegate row to this address — and the model is still never offered it.
  def test_under_the_delegate_flag_the_declaration_names_rhos_own_summarizer
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    config = Rho::Config.from_hash({ "plugins" => { "rho.compaction" => { "configuration_version" => 1, "configuration" => { "mode" => "delegate", "model" => "dev/mock-text" } } } })
    adopted(api, config: config)

    configuration = declared(api)
    assert_equal({ "mode" => "delegate", "tool_name" => "summarize_history" }, configuration.fetch("compaction_policy"))
    refute_includes configuration.fetch("tool_definitions").map { |entry| entry.dig("function", "name") },
      "summarize_history"
  end

  # A declaration the address cannot serve would fail every wall
  # `tool_not_served`: with the flag set and the extension not loaded, the
  # daemon declares compaction off rather than publishing an unserved delegate.
  def test_a_delegate_selection_without_the_extension_declares_compaction_off
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    config = Rho::Config.from_hash({ "plugins" => { "rho.compaction" => { "configuration_version" => 1, "configuration" => { "mode" => "delegate", "model" => "dev/mock-text" } } } })
    daemon, = adopted(api, config: config, extensions: [Rho::Runner::Extensions::Coding])

    assert_equal({ "mode" => "off" }, declared(api).fetch("compaction_policy"))
    refute_includes daemon.context.registry.names, "summarize_history"
  end

  # An unreachable catalog is a smaller declaration, never a missing one:
  # the machine's own tools still reach the profile.
  def test_a_kernel_catalog_that_cannot_be_read_costs_only_the_kernel_tools
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE])
    adopted(api)

    names = declared(api).fetch("tool_definitions").map { |entry| entry.dig("function", "name") }
    assert_includes names, "code"
    assert_equal ["0199-runner"], declared(api).fetch("runner_executor_public_ids")
    assert_empty declared(api).fetch("kernel_tools")
    refute_includes names, "delegate_task"
  end

  # `rho env` REBUILDS PLACEMENT ZERO, NEVER THE RUNNER: a claim resolves its placement on the worker, so
  # the runner stands on the new root — the same object, its meters its
  # own and monotonic by construction — the announcement is written again
  # and the declaration is not (it reads the registry, never the root),
  # and the lineage's socket and store rows are left as they are.
  def test_repointing_the_tools_rebuilds_placement_zero_and_declares_nothing_again
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: FLAT)
    daemon, token = adopted(api)
    declared(api)
    announced(api)
    wait_for { status_runner(daemon, token).fetch("swept").positive? }
    swept_before = status_runner(daemon, token).fetch("swept")
    runner = daemon.lineage.runner(:runner)
    root = File.join(@root, "elsewhere")
    FileUtils.mkdir_p(root)

    response = request(daemon, :post, "/environment", token: token, body: { "root" => root })

    assert_equal "200", response.code, response.body
    assert_equal announced(api, 1), announced(api, 2), "the runner half ran: the same announcement, written again"
    assert_same runner, daemon.lineage.runner(:runner), "the runner stands"
    assert_equal File.realpath(root), File.realpath(daemon.context.tool_env.root), "placement zero moved"
    after = status_runner(daemon, token)
    assert_operator after.fetch("swept"), :>=, swept_before, "the one runner's own meter, monotonic"
    assert_equal 0, after.fetch("nudged"), "the runner's other meter is served beside swept"
    assert_equal 1, api.configuration_declarations.length, "the same bytes would have been written: nothing was"
    assert_equal 1, File.read(daemon.home.log_path, encoding: Encoding::UTF_8).scan("event=profile.declared").length
  end

  # THE GUIDELINE AT BOOT: the runner-independent
  # guideline is rho's `system_prompt` slot on its profile — the first
  # system-role item of every assembled turn, ahead of memory, inside the
  # stable prefix — written atomically with the declaration,
  # and the per-request lead no longer carries it.
  def test_the_guideline_is_written_in_one_request_with_the_profiles_configuration
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    daemon, = adopted(api)
    declared(api)

    wait_for { api.prompt_document_writes.length >= 1 }
    slot, body = api.prompt_document_writes.fetch(0)
    assert_equal "system_prompt", slot
    assert_equal({ "prompt_document" => { "content" => Rho::RunDeclaration::GUIDELINE } }, body,
      "the shared policy stays in the stable prefix; the template places the current kind after history")
    assert_includes body.fetch("prompt_document").fetch("content"), Rho::MemoryPolicy::PROMPT
    assert_includes body.fetch("prompt_document").fetch("content"), Rho::ExecutionPolicy::PROMPT
    assert_equal body.fetch("prompt_document"), api.configuration_declarations.last.dig("prompt_documents", "system_prompt")
    refute api.requests.any? { |path, _| path.start_with?("/agent_api/v1/profile/prompt_documents/") },
      "the configuration and both slots share one PUT"
    wait_for { File.read(daemon.home.log_path, encoding: Encoding::UTF_8).include?("event=profile.declared") }
    assert_match(/event=profile\.declared .*prompt=system_prompt/, File.read(daemon.home.log_path, encoding: Encoding::UTF_8))
  end

  # THE SUMMARIZER SLOT AT DECLARE:
  # the slot row's `summarizer_prompt` — the pinned row, else the row of
  # `compaction.model || default_model` — lands in the profile's
  # `summarizer` slot beside the guideline, under the SAME tuple, and only
  # under a kernel policy. A text-less row clears the slot in the same PUT:
  # the declaration is recorded, `profile.declared` is
  # logged, and the next edge with the same bytes writes nothing.
  def summarizer_row(id, **fields)
    RhoTest::LocalRows.write(File.join(@root, "adaptations"), id, **fields)
  end

  def slot_log(daemon) = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)

  def test_the_slot_rows_summarizer_prompt_is_written_beside_the_guideline_under_the_kernel_policy
    summarizer_row("mock", models: ["mock-text"], summarizer_prompt: "Summarize by pointers.")
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    daemon, = adopted(api, config: Rho::Config.from_hash(
      { "default_model" => "dev/mock-text", "plugins" => { "rho.compaction" => { "configuration_version" => 1, "configuration" => { "mode" => "kernel" } } } }
    ))
    configuration = declared(api)

    assert_equal({ "mode" => "kernel" }, configuration.fetch("compaction_policy"),
      "the declared policy is the mode alone")
    wait_for { api.prompt_document_writes.length >= 2 }
    assert_equal [["system_prompt", Rho::RunDeclaration::GUIDELINE], ["summarizer", "Summarize by pointers."]],
      api.prompt_document_writes.map { |slot, body| [slot, body.dig("prompt_document", "content")] }
    assert_empty api.prompt_document_deletes
    wait_for { slot_log(daemon).include?("event=profile.declared") }
    assert_match(/event=profile\.declared .*prompt=system_prompt summarizer=written/, slot_log(daemon))

    daemon.context.declare_profile
    assert_equal 1, api.configuration_declarations.length, "the same tuple: nothing written again"
    assert_equal 2, api.prompt_document_writes.length
  end

  def test_a_text_less_row_clears_the_slot_in_the_complete_declaration
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    daemon, = adopted(api)
    declared(api)

    wait_for { api.prompt_document_deletes.length >= 1 }
    assert_equal ["summarizer"], api.prompt_document_deletes
    assert_equal ["system_prompt"], api.prompt_document_writes.map(&:first), "the default row carries no text"
    wait_for { slot_log(daemon).include?("event=profile.declared") }
    assert_match(/event=profile\.declared .*summarizer=deleted/, slot_log(daemon))
    assert_nil api.configuration_declarations.last.dig("prompt_documents", "summarizer")

    daemon.context.declare_profile
    assert_equal 1, api.configuration_declarations.length, "recorded: the next edge writes nothing"
    assert_equal 1, api.prompt_document_deletes.length
  end

  def test_an_explicit_summary_model_reaches_the_kernel_beside_its_adapted_prompt
    summarizer_row("summary", models: ["summary-text"], summarizer_prompt: "Summarize by pointers.")
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    _daemon, = adopted(api, config: Rho::Config.from_hash(
      { "default_model" => "dev/mock-text", "plugins" => { "rho.compaction" => { "configuration_version" => 1, "configuration" => { "mode" => "kernel", "model" => "dev/summary-text" } } } }
    ))
    configuration = declared(api)

    assert_equal({ "mode" => "kernel", "model" => "dev/summary-text" }, configuration.fetch("compaction_policy"))
    assert_equal "dev/mock-text", configuration.fetch("default_model")
    wait_for { api.prompt_document_writes.length >= 2 }
    assert_equal ["summarizer", { "prompt_document" => { "content" => "Summarize by pointers." } }],
      api.prompt_document_writes.last
  end

  def test_a_delegate_policy_deletes_the_slot_although_the_row_carries_a_text
    summarizer_row("mock", models: ["mock-text"], summarizer_prompt: "Summarize by pointers.")
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG)
    daemon, = adopted(api, config: Rho::Config.from_hash(
      { "default_model" => "dev/mock-text", "plugins" => { "rho.compaction" => { "configuration_version" => 1, "configuration" => { "mode" => "delegate", "model" => "dev/mock-text" } } } }
    ))
    configuration = declared(api)

    assert_equal "delegate", configuration.dig("compaction_policy", "mode")
    wait_for { api.prompt_document_deletes.length >= 1 }
    assert_equal ["summarizer"], api.prompt_document_deletes, "write only what is read: a delegate reads its own text"
    assert_equal ["system_prompt"], api.prompt_document_writes.map(&:first)
    wait_for { slot_log(daemon).include?("event=profile.declared") }
    assert_match(/event=profile\.declared .*compaction=delegate .*summarizer=deleted/, slot_log(daemon))
  end

  # A refused prompt rejects the whole declaration; the next edge retries
  # its complete body because no successful declaration digest was recorded.
  def test_a_refused_prompt_leaves_the_complete_declaration_to_the_next_edge
    refusal = CybrosAgent::Response.new(
      status: 422, headers: {},
      body: { "error" => { "code" => "prompt_document_too_large", "message" => "Content is too large" } }
    )
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], tools: CATALOG, prompt_document: refusal)
    daemon, = adopted(api)
    declared(api)
    wait_for { File.read(daemon.home.log_path, encoding: Encoding::UTF_8).include?("profile.declaration_failed") }
    assert_includes File.read(daemon.home.log_path, encoding: Encoding::UTF_8), "prompt_document_too_large"
    assert_empty api.prompt_document_writes
    assert_empty api.prompt_document_deletes

    # The next edge that declares — a set_default_runner's `declare_profile` — with the
    # SAME bytes: recorded, it would write nothing; unrecorded, both again.
    daemon.context.declare_profile

    assert_equal 2, api.configuration_declarations.length, "the same bytes, written again: the pair never landed"
    assert_equal api.configuration_declarations.first, api.configuration_declarations.last
    assert_empty api.prompt_document_writes
    refute_includes File.read(daemon.home.log_path, encoding: Encoding::UTF_8), "event=profile.declared"
  end

  # A refusal costs the declaration and is written down; the runner it
  # describes still takes work. The refusal is the kernel's own word for
  # a declaration it will not keep — `validation_failed` naming the field.
  def test_a_refused_declaration_is_logged_and_the_runner_still_runs
    refusal = CybrosAgent::Response.new(
      status: 422, headers: {},
      body: { "error" => { "code" => "validation_failed", "message" => "Approval rules has a rule with the unknown key scope" } }
    )
    api = NexusDoubles::FakeAgentApi.new(workspaces: [WORKSPACE], configuration: refusal)
    daemon, token = adopted(api)
    declared(api)

    wait_for do
      File.read(daemon.home.log_path, encoding: Encoding::UTF_8).include?("profile.declaration_failed")
    end
    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    assert_includes log, "validation_failed"
    runner = JSON.parse(request(daemon, :get, "/runner", token: token).body).fetch("runner")
    assert runner.fetch("running"), "a refused declaration is not a reason to stop taking work"
  end
end
