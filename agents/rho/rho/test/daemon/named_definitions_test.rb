require "test_helper"
require "support/nexus_doubles"
require "support/daemon_harness"

# THE DECLARE EDGE'S NAMED HALF (declared / kept-steward / removed / digest-gated / force / the rate of requests N + 2), over the fake kernel: at every edge
# the daemon scans `.agents/agents/*.md` at its environment root, reads
# `GET profile/agents`, PUTs each definition as its derived declaration
# under its current scope, DELETEs the instance rows whose file went, and
# retains the roster for the turn lead while the system guideline stays fixed —
# all under the one tuple, so an unchanged set writes nothing.
class DaemonNamedDefinitionsTest < Minitest::Test
  include RhoTest::DaemonHarness

  SIBLING = {
    "public_id" => "na-sib", "handle" => "docs", "kind" => "agent", "name" => "docs", "display_name" => "docs",
    "agent_identifier" => "rho.19c0aa77/docs", "steward_public_id" => "0199-steward", "scope" => "steward",
    "description" => "Writes the docs for a change and answers with the paths it wrote",
    "derived_from_public_id" => "0199-rho-b",
    "configuration" => { "tool_definitions" => [], "kernel_tools" => [], "runner_executor_public_ids" => [],
                         "runner_tool_names" => nil, "approval_mode" => "bypass", "approval_rules" => nil,
                         "prompt_mechanism" => "default", "prompt_template" => nil, "compaction_policy" => nil,
                         "default_model" => nil },
  }.freeze
  RHO_B = { "public_id" => "0199-rho-b", "handle" => "rho-b", "kind" => "agent", "display_name" => "rho on b",
            "agent_identifier" => "rho.19c0aa77", "steward_public_id" => "0199-steward" }.freeze

  # The fake's own profile is this daemon's identity, so the rows it mints
  # read as this daemon's own (`derived_from_public_id`).
  def fake(**options) = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, **options)

  def ready(api)
    daemon = member_ready(boot, api, identity: RUNNER_IDENTITY)
    FileUtils.mkdir_p(root(daemon))
    daemon
  end

  def root(daemon) = daemon.context.environment.root

  def write_definition(daemon, name, text, directory: ".agents/agents")
    dir = File.join(root(daemon), directory)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.md"), text, encoding: "UTF-8")
    File.join(dir, "#{name}.md")
  end

  REVIEWER = "---\ndescription: Reviews a diff for defects.\ntools: read, grep\n---\nYou review. REVIEWER-BODY-7\n".freeze
  DOCS = "---\ndescription: Writes the docs.\ntools: []\nmodel: dev/mock-text-only\n---\n".freeze

  def slot_writes(api) = api.prompt_document_writes.select { |slot, _| slot == "system_prompt" }.map { |_, body| body.dig("prompt_document", "content") }

  def declarations(api) = api.named_agent_declarations.map { |name, body| [name, body.fetch("scope")] }

  def log(daemon) = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)

  def request_paths(api) = api.requests.map(&:first)

  # ---- the edge ----

  def test_full_mode_keeps_code_in_named_definitions_without_agent_only_tools
    api = fake
    daemon = ready(api)
    write_definition(daemon, "author", "---\ndescription: Authors work.\ntools: code, todo_write, summarize_history\n---\n")

    assert_equal :declared, daemon.context.declare_profile
    configuration = api.named_agent_declarations.to_h.fetch("author").fetch("configuration")
    assert_empty configuration.fetch("tool_definitions")
    assert_empty configuration.fetch("kernel_tools")
    assert_equal [RUNNER_IDENTITY.runner_executor_public_id], configuration.fetch("runner_executor_public_ids")
    assert_equal ["code"], configuration.fetch("runner_tool_names")
  end

  def test_agent_mode_derives_remote_runner_code_without_copying_the_agent_tool
    loaded = Rho::Runner::Extensions::Loader.call(builtin: [], gems: ["rho/codemode"])
    served = Rho::RunDeclaration.announcement(registry: loaded.registry)
    api = fake(executors: [NexusDoubles.remote_runner("remote-code", tools: served)])
    daemon = member_ready(boot(config: agent_mode), api)
    write_definition(daemon, "author", "---\ndescription: Authors work.\ntools: code, todo_write\n---\n")

    assert_equal :declared, daemon.context.declare_profile
    main = api.configuration_declarations.last.dig("configuration", "tool_definitions")
    assert_includes main.map { |entry| entry.dig("function", "name") }, "code"
    configuration = api.named_agent_declarations.to_h.fetch("author").fetch("configuration")
    assert_empty configuration.fetch("tool_definitions")
    assert_equal ["remote-code"], configuration.fetch("runner_executor_public_ids")
    assert_equal ["code"], configuration.fetch("runner_tool_names")

    File.write(daemon.home.settings_path, JSON.generate("runner" => "remote-code"))
    assert_equal :unchanged, daemon.context.declare_profile, "a default selection does not change candidate authority"
    assert_equal 1, api.named_agent_declarations.length
    assert_equal configuration, api.named_agent_declarations.to_h.fetch("author").fetch("configuration")
  end

  def test_named_definitions_exclude_editor_tools_and_keep_kernel_aliases_and_runner_intentions
    anchor = CybrosAgent::ModelAdaptations.load.presets.preset("claude").aliases.first.dig("recut", "anchor")
    catalog = NexusDoubles::KERNEL_CATALOG.map { |row| row.merge("template" => "The task verb.\n\n#{anchor}") }
    remote = NexusDoubles.remote_runner("remote-editor", tools: [NexusDoubles.served_tool("mcp__fx__lookup"), NexusDoubles.served_tool("read")])
    api = fake(tools: catalog, executors: [remote])
    extension = RhoTest::ConversationServers.extension(@root, closes: File.join(@root, "closes.txt"))
    config = Rho::Config.from_hash({ "adaptations" => "claude", "kernel_tools" => NexusDoubles::KERNEL_TOOLS.keys,
      "plugins" => { "rho.mcp" => { "enabled" => false }, "rho.servers" => extension } })
    daemon = member_ready(boot(config: config), api, identity: RUNNER_IDENTITY)
    write_definition(daemon, "all", "---\ndescription: Uses inherited tools.\n---\n")
    write_definition(daemon, "selected", "---\ndescription: Selects tools.\ntools: Agent, mcp__fx__lookup, mcp__fx__paths, read\n---\n")
    response = capturing_spawns(daemon) do
      request(daemon, :post, "/conversations", token: bearer(daemon), body: { environment: { root: root(daemon) } })
    end
    assert_equal "201", response.code, response.body
    conversation = JSON.parse(response.body).dig("conversation", "public_id")

    response = request(daemon, :post, "/conversations/environment", token: bearer(daemon),
      body: { public_id: conversation, mcp: [RhoTest::ConversationServers.stdio("fx")] })

    assert_equal "200", response.code, response.body
    parent = api.configuration_declarations.last.fetch("configuration")
    parent_tools = parent.fetch("tool_definitions")
    assert_includes parent_tools.map { |entry| entry.dig("function", "name") }, "mcp__fx__lookup"
    assert_includes parent_tools.map { |entry| entry.dig("function", "name") }, "mcp__fx__paths"
    aliases = parent_tools.select { |entry| entry.key?("canonical") }
    assert_equal ["Agent"], aliases.map { |entry| entry.dig("function", "name") }
    inherited = api.named_agent_declarations.to_h.fetch("all").fetch("configuration")
    selected = api.named_agent_declarations.to_h.fetch("selected").fetch("configuration")
    [inherited, selected].each do |configuration|
      assert_equal aliases, configuration.fetch("tool_definitions"), "addressless named Agents retain only kernel aliases"
      assert_equal parent.fetch("kernel_tools"), configuration.fetch("kernel_tools")
      assert_equal parent.fetch("runner_executor_public_ids"), configuration.fetch("runner_executor_public_ids")
    end
    assert_nil inherited.fetch("runner_tool_names"), "omitting tools inherits all selected Runner tools"
    assert_equal %w[mcp__fx__lookup read], selected.fetch("runner_tool_names"),
      "the Runner's original name survives an editor tool with the same name"
  end

  # Two files, one edge: two PUTs under `instance` with the derived
  # declaration (the reviewer's names exactly `grep`, `read`; docs' `[]`
  # with the mode written, `default_model` from the file), a fixed system
  # guideline and a separate turn roster, N + 2 member-plane requests beside the
  # profile's own writes, and `:unchanged` on the next edge.
  def test_the_edge_declares_each_definition_and_keeps_the_roster_out_of_the_system_slot
    api = fake
    daemon = ready(api)
    write_definition(daemon, "reviewer", REVIEWER)
    write_definition(daemon, "docs", DOCS)
    before = api.requests.length

    assert_equal :declared, daemon.context.declare_profile

    assert_equal [["docs", "instance"], ["reviewer", "instance"]], declarations(api)
    reviewer = api.named_agent_declarations.to_h.fetch("reviewer")
    assert_empty reviewer.dig("configuration", "tool_definitions")
    assert_empty reviewer.dig("configuration", "kernel_tools")
    assert_equal [RUNNER_IDENTITY.runner_executor_public_id], reviewer.dig("configuration", "runner_executor_public_ids")
    assert_equal %w[read grep], reviewer.dig("configuration", "runner_tool_names")
    assert_equal "You review. REVIEWER-BODY-7", reviewer.fetch("system_prompt")
    assert_equal "Reviews a diff for defects.", reviewer.fetch("description")
    assert_equal "reviewer", reviewer.fetch("display_name")
    assert_nil reviewer.dig("configuration", "default_model")
    docs = api.named_agent_declarations.to_h.fetch("docs")
    assert_equal [], docs.dig("configuration", "tool_definitions")
    assert_equal [], docs.dig("configuration", "kernel_tools")
    assert_equal [], docs.dig("configuration", "runner_tool_names")
    assert_equal "bypass", docs.dig("configuration", "approval_mode")
    assert_equal "dev/mock-text-only", docs.dig("configuration", "default_model")
    assert_nil docs.fetch("system_prompt")
    own = api.configuration_declarations.fetch(0).fetch("configuration")
    assert_equal own.fetch("approval_rules"), reviewer.dig("configuration", "approval_rules"), "the parent's rules whole"

    assert_equal [Rho::RunDeclaration::GUIDELINE], slot_writes(api)
    assert_equal <<~TEXT.strip, daemon.context.agent_roster
      #{Rho::RunDeclaration::ROSTER_HEADING}
      - @docs: Writes the docs.
      - @reviewer: Reviews a diff for defects.
    TEXT

    named = request_paths(api).drop(before).select { |path| path.include?("/profile/agents") }
    assert_equal ["/agent_api/v1/profile/agents", "/agent_api/v1/profile/agents/docs", "/agent_api/v1/profile/agents/reviewer"],
      named, "one GET, N PUTs, no DELETE: N + 1 requests on this edge"
    assert_match(/event=agents\.declared declared=2 removed=0 failed=0 skipped=0/, log(daemon))
    assert_match(/event=profile\.declared .*agents=2/, log(daemon))

    assert_equal :unchanged, daemon.context.declare_profile, "the same files and rows move nothing"
    assert_equal 2, api.named_agent_declarations.length
    assert_equal 1, api.configuration_declarations.length
  end

  # No definition: the slot keeps its stable guideline, and no
  # PUT is made; a listing is still read (a stale row could be there).
  def test_no_definition_leaves_the_slot_without_a_roster
    api = fake
    daemon = ready(api)

    assert_equal :declared, daemon.context.declare_profile

    assert_equal [Rho::RunDeclaration::GUIDELINE], slot_writes(api)
    assert_empty api.named_agent_declarations
    assert_equal 1, request_paths(api).count("/agent_api/v1/profile/agents")
  end

  def test_a_conversation_turn_carries_the_current_roster_in_its_lead
    api = fake(trace: NexusDoubles::RUNNING_TRACE)
    daemon = ready(api)
    write_definition(daemon, "reviewer", REVIEWER)
    daemon.context.declare_profile

    response = request(daemon, :post, "/conversations", token: bearer(daemon),
      body: { prompt: "review this change", model: "dev/mock-text" })

    assert_equal "201", response.code, response.body
    lead = api.conversation_inputs.last.dig("input", "inline").find { |entry| entry.fetch("position") == "lead" }.fetch("text")
    assert_includes lead, "- @reviewer: Reviews a diff for defects."
    refute_includes lead, "(tools:"
    assert_equal [Rho::RunDeclaration::GUIDELINE], slot_writes(api)
  end

  # No root — nothing connected — reads nothing and authors no roster.
  def test_no_root_reads_nothing
    api = fake
    daemon = member_ready(boot, api, identity: RUNNER_IDENTITY)
    daemon.context.define_singleton_method(:environment) { Rho::EnvironmentStore::Selection.new(root: nil, source: "unset") }

    assert_equal :declared, daemon.context.declare_profile

    assert_equal [Rho::RunDeclaration::GUIDELINE], slot_writes(api)
    assert_equal 0, request_paths(api).count("/agent_api/v1/profile/agents")
  end

  # THE REMOVAL EDGE: a file gone → the instance row DELETEd, the roster
  # without it; a changed file re-declares; a sibling's publish shows at
  # the next edge; a steward row whose file went stays, listed as last declared.
  def test_a_removed_file_deletes_its_instance_row_and_a_published_row_survives
    api = fake
    daemon = ready(api)
    write_definition(daemon, "reviewer", REVIEWER)
    docs = write_definition(daemon, "docs", DOCS)
    daemon.context.declare_profile
    daemon.context.sync_named_definitions(publish: "reviewer")
    assert_equal [["docs", "instance"], ["reviewer", "instance"], ["docs", "instance"], ["reviewer", "steward"]],
      declarations(api)

    File.delete(docs)
    assert_equal :declared, daemon.context.declare_profile
    assert_equal ["docs"], api.named_agent_deletes
    assert_equal ["reviewer"], api.named_agent_declarations.last(1).map(&:first)
    assert_equal "steward", api.named_agent_declarations.last.last.fetch("scope"), "the published name stays published"
    assert_match(/- @reviewer: /, daemon.context.agent_roster)
    refute_match(/- @docs: /, daemon.context.agent_roster)
    assert_match(/event=agents\.removed name=docs reason="the file is gone"/, log(daemon))

    File.delete(File.join(root(daemon), ".agents/agents/reviewer.md"))
    assert_equal :declared, daemon.context.declare_profile
    assert_equal ["docs"], api.named_agent_deletes, "a steward row is never deleted by the edge"
    assert_match(/- @reviewer: Reviews a diff for defects\./, daemon.context.agent_roster,
      "kept as last declared, still in the roster")
    assert_equal :unchanged, daemon.context.declare_profile
  end

  # A changed file re-declares; the roster follows the kernel's handle
  # (a `-2` past a collision), never the name.
  def test_a_changed_file_re_declares_and_the_roster_carries_the_kernels_handle
    api = fake(named_agents: [SIBLING.merge("scope" => "instance", "derived_from_public_id" => "0199-other", "name" => "reviewer",
      "handle" => "reviewer", "public_id" => "na-other")])
    daemon = ready(api)
    write_definition(daemon, "reviewer", REVIEWER)
    daemon.context.declare_profile
    assert_match(/- @reviewer-2: Reviews a diff for defects\./, daemon.context.agent_roster, "the name is taken account-wide")
    assert_equal :unchanged, daemon.context.declare_profile

    write_definition(daemon, "reviewer", REVIEWER.sub("read, grep", "read"))
    assert_equal :declared, daemon.context.declare_profile
    assert_match(/- @reviewer-2: Reviews a diff for defects\./, daemon.context.agent_roster)
  end

  # A sibling's published row rides the roster from the listing, shadowed
  # by an own row of the same name; `rho agents` still lists it.
  def test_a_siblings_published_row_is_in_the_roster_unless_an_own_name_shadows_it
    api = fake(named_agents: [SIBLING], principals: [RHO_B])
    daemon = ready(api)
    write_definition(daemon, "reviewer", REVIEWER)

    daemon.context.declare_profile
    assert_equal ["- @reviewer: Reviews a diff for defects.",
                  "- @docs: Writes the docs for a change and answers with the paths it wrote"],
      daemon.context.agent_roster.lines.map(&:chomp).last(2)

    write_definition(daemon, "docs", DOCS)
    assert_equal :declared, daemon.context.declare_profile
    lines = daemon.context.agent_roster.lines.map(&:chomp)
    assert_equal 1, lines.count { |line| line.start_with?("- @docs") }, "one line per name: the own row shadows"
    assert_includes lines, "- @docs-2: Writes the docs."

    listing = daemon.context.list_named_definitions
    nexus = listing.dig(:agents, :nexus)
    assert_equal [{ handle: "docs", from: "rho-b", shadowed_by: File.join(root(daemon), ".agents/agents/docs.md") }],
      nexus.map { |row| row.slice(:handle, :from, :shadowed_by) }
    assert_equal %w[docs-2 reviewer], listing.dig(:agents, :instance).map { |row| row[:handle] }
  end

  # THE PER-FILE REFUSAL: the kernel refuses one declaration (a bare model
  # alias); that file costs itself for the boot, logged and redacted, and
  # the edge lands the rest.
  def test_a_kernel_refusal_of_one_file_costs_that_file_alone
    refusal = CybrosAgent::Response.new(status: 422, headers: {},
      body: { "error" => { "code" => "validation_failed", "message" => "default_model sonnet is not authorized" } })
    api = fake(named_agent: ->(name, _body) { name == "strong" ? refusal : :accept })
    daemon = ready(api)
    write_definition(daemon, "reviewer", REVIEWER)
    write_definition(daemon, "strong", "---\ndescription: Strong.\nmodel: sonnet\n---\n")

    assert_equal :declared, daemon.context.declare_profile

    assert_equal %w[reviewer strong], api.named_agent_declarations.map(&:first)
    assert_match(/- @reviewer: /, daemon.context.agent_roster)
    refute_match(/- @strong: /, daemon.context.agent_roster)
    assert_match(/event=agents\.declaration_failed name=strong code=validation_failed/, log(daemon))
    assert_match(/event=agents\.declared declared=1 removed=0 failed=1 skipped=0/, log(daemon))
  end

  # THE SCAN'S SKIPS are logged at the edge with the file and the reason.
  def test_a_skipped_file_is_logged_at_the_edge
    api = fake
    daemon = ready(api)
    write_definition(daemon, "old", "---\nname: old\n---\nBody\n", directory: ".claude/agents")

    daemon.context.declare_profile

    assert_match(%r{event=agents\.skipped path=".*\.claude/agents/old\.md" reason="description is required"}, log(daemon))
    assert_empty api.named_agent_declarations
  end

  # A refused listing is the edge's own refusal: nothing declared, the
  # tuple unrecorded, the next edge tries again.
  def test_a_refused_door_refuses_the_edge_and_the_next_edge_tries_again
    api = fake
    daemon = ready(api)
    write_definition(daemon, "reviewer", REVIEWER)
    refusing = Object.new
    refusing.define_singleton_method(:call) do |path, **options|
      if path == "/agent_api/v1/profile/agents"
        CybrosAgent::Response.new(status: 503, headers: {}, body: { "error" => { "code" => "unavailable", "message" => "later" } })
      else
        api.call(path, **options)
      end
    end
    daemon.wire.api_transport = refusing

    outcome = daemon.context.declare_profile
    assert_kind_of Rho::Daemon::HostFollowers::Refused, outcome
    assert_empty api.configuration_declarations, "the plan is read before anything is written"

    daemon.wire.api_transport = api
    assert_equal :declared, daemon.context.declare_profile
    assert_equal ["reviewer"], api.named_agent_declarations.map(&:first)
  end

  # ---- the verbs' facts ----

  # `sync` runs the edge past the tuple and answers the names.
  def test_sync_runs_the_edge_past_the_tuple_and_answers_its_facts
    api = fake
    daemon = ready(api)
    write_definition(daemon, "reviewer", REVIEWER)
    docs = write_definition(daemon, "docs", DOCS)
    write_definition(daemon, "old", "---\n---\n", directory: ".claude/agents")
    daemon.context.declare_profile
    assert_equal :unchanged, daemon.context.declare_profile

    edge = daemon.context.sync_named_definitions
    assert_equal %w[docs reviewer], edge.declared
    assert_equal [], edge.removed
    assert_equal 1, edge.skipped.length
    assert_equal 4, api.named_agent_declarations.length, "past the tuple: every definition PUT again"

    File.delete(docs)
    edge = daemon.context.sync_named_definitions
    assert_equal %w[reviewer], edge.declared
    assert_equal %w[docs], edge.removed
  end

  # `publish` flips the one row's scope; the answer carries the kernel's row.
  def test_publish_flips_the_rows_scope_and_the_next_edge_keeps_it
    api = fake
    daemon = ready(api)
    write_definition(daemon, "reviewer", REVIEWER)
    daemon.context.declare_profile

    edge = daemon.context.sync_named_definitions(publish: "reviewer")

    answer = edge.answers.fetch("reviewer")
    assert_equal "steward", answer.scope
    assert_equal "na-1", answer.public_id, "the same row"
    assert_equal "reviewer", answer.handle
    assert_equal [["reviewer", "instance"], ["reviewer", "steward"]], declarations(api)
    assert_equal :unchanged, daemon.context.declare_profile, "the post-state was recorded"
    daemon.context.sync_named_definitions
    assert_equal "steward", api.named_agent_declarations.last.last.fetch("scope"), "the publisher keeps it fresh under its scope"
  end

  # `rm` removes this daemon's own row of the name, either scope, and says
  # whether the file still defines it; a sibling's row is not this
  # daemon's to remove; an unknown name is the kernel's 404.
  def test_rm_removes_the_own_row_and_refuses_a_siblings
    api = fake(named_agents: [SIBLING], principals: [RHO_B])
    daemon = ready(api)
    path = write_definition(daemon, "reviewer", REVIEWER)
    daemon.context.declare_profile

    minted = api.named_agents_listing.body.fetch("agents").find { |row| row.fetch("name") == "reviewer" }.fetch("public_id")

    answer = daemon.context.remove_named_definition("reviewer")
    assert_equal "reviewer", answer.dig(:removed, :handle)
    assert_equal minted, answer.dig(:removed, :public_id)
    assert_equal "rho.fake/reviewer", answer.dig(:removed, :agent_identifier)
    assert_equal path, answer.fetch(:file)
    assert_equal ["reviewer"], api.named_agent_deletes
    assert_match(/event=agents\.removed name=reviewer handle=reviewer scope=instance/, log(daemon))

    sibling = daemon.context.remove_named_definition("docs")
    assert_kind_of Rho::Daemon::Refusal, sibling
    assert_equal [404, "published_by_sibling", "docs is @rho-b's published definition; the steward removes it on the agents page"],
      [sibling.status, sibling.code, sibling.message]

    unknown = daemon.context.remove_named_definition("nobody")
    assert_equal [404, "not_found"], [unknown.status, unknown.code]
    assert_equal ["reviewer"], api.named_agent_deletes

    assert_equal :declared, daemon.context.declare_profile, "the file still defines it: the next edge restores the row"
    restored = api.named_agents_listing.body.fetch("agents").find { |row| row.fetch("name") == "reviewer" }
    assert_equal minted, restored.fetch("public_id"), "the same row, restored"
  end

  # THE REPOINT RE-RUNS THE EDGE: `rho env DIR` moves the root, and the
  # definitions there are declared; back to the settings, the old ones go.
  def test_a_repoint_re_runs_the_edge_at_the_new_root
    api = fake
    daemon = ready(api)
    daemon.context.declare_profile
    assert_equal [Rho::RunDeclaration::GUIDELINE], slot_writes(api)
    checkout = File.join(@root, "checkout")
    FileUtils.mkdir_p(File.join(checkout, ".agents/agents"))
    File.write(File.join(checkout, ".agents/agents/reviewer.md"), REVIEWER)

    selection = daemon.context.repoint_tools(checkout)

    assert_equal File.realpath(checkout), File.realpath(selection.root)
    assert_equal ["reviewer"], api.named_agent_declarations.map(&:first)
    assert_match(/- @reviewer: /, daemon.context.agent_roster)

    daemon.context.repoint_tools(nil)
    assert_equal ["reviewer"], api.named_agent_deletes, "no file at the settings' root: the instance row goes"
    assert_equal Rho::RunDeclaration::GUIDELINE, slot_writes(api).last
  end

  # A runner-mode daemon holds no member plane: the verbs say so.
  def test_a_runner_mode_daemon_refuses_the_verbs
    daemon = boot(config: runner_mode)

    assert_equal "member_plane_unavailable", daemon.context.list_named_definitions.code
    assert_equal "member_plane_unavailable", daemon.context.sync_named_definitions.code
    assert_equal "member_plane_unavailable", daemon.context.remove_named_definition("x").code
  end
end
