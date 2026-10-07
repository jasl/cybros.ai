require "test_helper"
require "tmpdir"

# THE FOUR ROUTES AND THE FOUR VERBS: `GET /agents` the listing, `POST /agents/sync|publish|rm` the
# edge past its tuple, the scope flip and the removal — each over the
# daemon's facade; and `rho agents` printing the command's output against a
# scripted daemon. The declaration itself is the daemon's edge
# (`daemon/named_definitions_test`); this file is the surface.
class AgentsExtensionTest < Minitest::Test
  include RhoTest::DaemonHarness

  SIBLING = {
    "public_id" => "na-sib", "handle" => "docs-2", "kind" => "agent", "name" => "docs", "display_name" => "docs",
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
  REVIEWER = "---\ndescription: Reviews a diff for defects.\ntools: read, grep\nmodel: dev/text\n---\nYou review.\n".freeze

  def fake(**options) = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, **options)

  def ready(api)
    daemon = member_ready(boot, api, identity: RUNNER_IDENTITY)
    FileUtils.mkdir_p(daemon.context.environment.root)
    daemon
  end

  def write_definition(daemon, name, text, directory: ".agents/agents")
    dir = File.join(daemon.context.environment.root, directory)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.md"), text, encoding: "UTF-8")
    File.join(dir, "#{name}.md")
  end

  def call(daemon, verb, path, body: nil)
    response = request(daemon, verb, path, token: bearer(daemon), body: body)
    [response.code, JSON.parse(response.body)]
  end

  def test_the_routes_are_the_extensions_and_demand_the_bearer
    daemon = boot
    assert_equal "401", request(daemon, :get, "/agents").code
    assert_equal "401", request(daemon, :post, "/agents/sync").code
    assert_equal "401", request(daemon, :post, "/agents/publish", body: { name: "x" }).code
    assert_equal "401", request(daemon, :post, "/agents/rm", body: { name: "x" }).code
    assert_includes Rho::Extensions::DEFAULT_EXTENSIONS, Rho::Extensions::Agents
    assert_equal ["rho.agents"], Rho::Extensions.load(host: RhoTest.host).commands.select { |c| c.name == "agents" }.map(&:extension)
  end

  # THE LISTING: the two homes, the paths, the publisher's handle, the
  # shadow, the skipped files; the kernel's row shape on every row.
  def test_get_agents_lists_the_two_homes_and_the_skipped_files
    api = fake(named_agents: [SIBLING], principals: [RHO_B])
    daemon = ready(api)
    reviewer = write_definition(daemon, "reviewer", REVIEWER)
    docs = write_definition(daemon, "docs", "---\ndescription: Writes the docs.\ntools: []\n---\n")
    old = write_definition(daemon, "old", "---\nname: old\n---\n", directory: ".claude/agents")
    daemon.context.declare_profile
    daemon.context.sync_named_definitions(publish: "docs")

    code, document = call(daemon, :get, "/agents")

    assert_equal "200", code, document.inspect
    assert_equal daemon.context.environment.root, document.fetch("root")
    instance = document.dig("agents", "instance")
    assert_equal [{ "handle" => "reviewer", "name" => "reviewer", "scope" => "instance", "description" => "Reviews a diff for defects.",
                    "model" => "dev/text", "tools" => %w[grep read], "path" => reviewer,
                    "agent_identifier" => "rho.fake/reviewer", "kind" => "agent", "display_name" => "reviewer",
                    "steward_public_id" => "0199-steward", "derived_from_public_id" => IDENTITY.user_public_id }],
      instance.map { |row| row.except("public_id", "configuration") }
    assert_equal %w[tool_definitions kernel_tools runner_executor_public_ids runner_tool_names approval_mode approval_rules
                    prompt_mechanism prompt_template compaction_policy default_model lifecycle_hooks fallback_model],
      instance.first.fetch("configuration").keys
    nexus = document.dig("agents", "nexus")
    assert_equal [{ "handle" => "docs", "scope" => "steward", "path" => docs, "tools" => [] },
                  { "handle" => "docs-2", "scope" => "steward", "from" => "rho-b", "shadowed_by" => docs, "tools" => [] }],
      nexus.map { |row| row.slice("handle", "scope", "path", "from", "shadowed_by", "tools") }
    assert_equal [{ "path" => old, "reason" => "description is required" }], document.fetch("skipped")
  end

  # THE FALLBACK COLUMN: each row's declared fallback on refusal — the
  # parent's for a definition that names no model (it runs on the
  # initiator's line), the file's own or none for one that does.
  def test_get_agents_lists_each_rows_fallback
    api = fake
    daemon = member_ready(boot(config: Rho::Config.from_hash({ "fallback_model" => "dev/fallback" })), api)
    FileUtils.mkdir_p(daemon.context.environment.root)
    write_definition(daemon, "reviewer", REVIEWER)
    write_definition(daemon, "docs", "---\ndescription: Writes the docs.\ntools: []\n---\n")
    write_definition(daemon, "fast", "---\ndescription: Fast.\nmodel: dev/text\n" \
                                     "fallback_model: dev/fallback\n---\n")
    daemon.context.declare_profile
    daemon.context.sync_named_definitions

    code, document = call(daemon, :get, "/agents")

    assert_equal "200", code, document.inspect
    assert_equal({ "docs" => "dev/fallback", "fast" => "dev/fallback", "reviewer" => nil },
      document.dig("agents", "instance").to_h { |row| [row.fetch("name"), row["fallback"]] })
  end

  def test_sync_publish_and_rm_answer_the_designs_shapes
    api = fake(named_agents: [SIBLING], principals: [RHO_B])
    daemon = ready(api)
    reviewer = write_definition(daemon, "reviewer", REVIEWER)
    write_definition(daemon, "old", "---\nname: old\n---\n", directory: ".claude/agents")

    code, document = call(daemon, :post, "/agents/sync")
    assert_equal "200", code, document.inspect
    assert_equal({ "declared" => ["reviewer"], "removed" => [], "skipped" => 1 }, document)

    code, document = call(daemon, :post, "/agents/publish", body: { name: "reviewer" })
    assert_equal "200", code, document.inspect
    assert_equal reviewer, document.fetch("path")
    assert_equal daemon.context.environment.root, document.fetch("root"), "the root the verb prints the path against"
    assert_equal %w[steward reviewer reviewer rho.fake/reviewer], document.fetch("agent").values_at("scope", "name", "handle", "agent_identifier")
    assert_equal "steward", api.named_agent_declarations.last.last.fetch("scope")

    code, document = call(daemon, :post, "/agents/publish", body: { name: "nobody" })
    assert_equal "404", code
    assert_equal({ "code" => "definition_not_found", "message" => "no definition named nobody; rho agents lists them" }, document.fetch("error"))

    code, document = call(daemon, :post, "/agents/publish", body: {})
    assert_equal "400", code
    assert_equal "name is required", document.dig("error", "message")

    code, document = call(daemon, :post, "/agents/rm", body: { name: "reviewer" })
    assert_equal "200", code, document.inspect
    assert_equal %w[reviewer rho.fake/reviewer steward], document.fetch("removed").values_at("handle", "agent_identifier", "scope")
    assert_equal reviewer, document.fetch("file")
    assert_equal daemon.context.environment.root, document.fetch("root")

    code, document = call(daemon, :post, "/agents/rm", body: { name: "docs" })
    assert_equal "404", code
    assert_equal "docs is @rho-b's published definition; the steward removes it on the agents page", document.dig("error", "message")

    code, document = call(daemon, :post, "/agents/rm", body: { name: "nobody" })
    assert_equal "404", code
    assert_equal "not_found", document.dig("error", "code")
  end

  # A per-file kernel refusal on the published name is the publish's 422.
  def test_publish_relays_a_refused_declaration
    refusal = CybrosAgent::Response.new(status: 422, headers: {},
      body: { "error" => { "code" => "validation_failed", "message" => "default_model sonnet is not authorized" } })
    api = fake(named_agent: ->(name, _body) { name == "strong" ? refusal : :accept })
    daemon = ready(api)
    write_definition(daemon, "strong", "---\ndescription: Strong.\nmodel: sonnet\n---\n")

    code, document = call(daemon, :post, "/agents/publish", body: { name: "strong" })

    assert_equal "422", code
    assert_equal "declaration_failed", document.dig("error", "code")
  end

  # ---- the verbs' printed lines ----

  class VerbsTest < Minitest::Test
    include RhoTest::CliHarness

    def agents(*args, **options) = Rho::Extensions::Agents::Commands.agents(cli, args, options)

    ROW = {
      "handle" => "reviewer", "name" => "reviewer", "description" => "Reviews a diff for defects", "scope" => "instance",
      "model" => "dev/text", "fallback" => "dev/fallback", "tools" => %w[bash find grep read],
      "path" => "/work/repo/.agents/agents/reviewer.md", "public_id" => "na-1", "agent_identifier" => "rho.7f3a9c1e/reviewer",
    }.freeze
    DOCS = ROW.merge("handle" => "docs", "name" => "docs", "description" => "Writes the docs for a change", "scope" => "steward",
      "model" => nil, "fallback" => nil, "tools" => [], "path" => "/work/repo/.agents/agents/docs.md",
      "agent_identifier" => "rho.7f3a9c1e/docs").freeze
    DOCS_B = DOCS.merge("handle" => "docs-2", "tools" => %w[bash edit read write], "from" => "rho-b",
      "shadowed_by" => "/work/repo/.agents/agents/docs.md", "agent_identifier" => "rho.19c0aa77/docs").except("path").freeze

    def test_agents_prints_the_two_homes_and_the_skipped_files
      listing = { "root" => "/work/repo", "agents" => { "instance" => [ROW], "nexus" => [DOCS, DOCS_B] },
                  "skipped" => [{ "path" => "/work/repo/.claude/agents/old.md", "reason" => "description is required" }] }
      announce(endpoint: routed_endpoint("GET /agents" => [[200, listing]]))

      agents(nil)

      assert_equal [
        "instance/  (.agents/agents, .claude/agents under /work/repo)",
        "  @reviewer   reviewer   Reviews a diff for defects   model: dev/text   " \
        "fallback: dev/fallback   tools: bash, find, grep, read",
        "    .agents/agents/reviewer.md",
        "nexus/  (published under the steward; every agent of this steward may spawn them)",
        "  @docs   docs   Writes the docs for a change   model: —   fallback: —   tools: none",
        "    .agents/agents/docs.md",
        "  @docs-2   docs   Writes the docs for a change   model: —   fallback: —   tools: bash, edit, read, write   from: @rho-b   " \
        "shadowed by .agents/agents/docs.md",
        "skipped:",
        "  .claude/agents/old.md: description is required",
      ], @out.string.lines.map(&:chomp)
    end

    def test_agents_says_when_no_root_is_set_and_when_nothing_is_defined
      none = { "root" => nil, "agents" => { "instance" => [], "nexus" => [] }, "skipped" => [] }
      announce(endpoint: routed_endpoint("GET /agents" => [[200, none]]))

      agents(nil)

      assert_equal ["instance/  (no root set; `rho env ROOT` points the daemon at one)", "  (none)",
                    "nexus/  (published under the steward; every agent of this steward may spawn them)", "  (none)"],
        @out.string.lines.map(&:chomp)
    end

    def test_sync_prints_the_counts_with_the_names
      announce(endpoint: routed_endpoint("POST /agents/sync" => [[200, { "declared" => %w[reviewer docs], "removed" => ["old"], "skipped" => 1 }],
                                                                 [200, { "declared" => [], "removed" => [], "skipped" => 0 }]]))
      agents("sync")
      agents("sync")
      assert_equal ["declared: 2 (reviewer, docs)   removed: 1 (old)   skipped: 1", "declared: 0   removed: 0   skipped: 0"],
        @out.string.lines.map(&:chomp)
    end

    def test_publish_and_rm_print_the_designs_lines_and_relay_the_daemons_sentence
      seen = []
      announce(endpoint: recording_routed_endpoint(seen,
        "POST /agents/publish" => [[200, { "agent" => ROW.merge("scope" => "steward"), "path" => "/work/repo/.agents/agents/reviewer.md",
                                           "root" => "/work/repo" }]],
        "POST /agents/rm" => [[200, { "removed" => ROW, "file" => "/work/repo/.agents/agents/reviewer.md", "root" => "/work/repo" }],
                              [200, { "removed" => DOCS, "file" => nil, "root" => "/work/repo" }],
                              [404, { "error" => { "code" => "published_by_sibling",
                                                   "message" => "docs is @rho-b's published definition; the steward removes it on the agents page" } }]]))

      agents("publish", "reviewer")
      agents("rm", "reviewer")
      agents("rm", "docs")
      error = assert_raises(Rho::Error) { agents("rm", "docs") }

      assert_equal "docs is @rho-b's published definition; the steward removes it on the agents page", error.message
      assert_equal [
        "published: @reviewer (rho.7f3a9c1e/reviewer) from .agents/agents/reviewer.md",
        "removed: @reviewer (rho.7f3a9c1e/reviewer); the file .agents/agents/reviewer.md still defines it — " \
        "delete the file or it returns at the next sync",
        "removed: @docs (rho.7f3a9c1e/docs)",
      ], @out.string.lines.map(&:chomp)
      assert_equal({ "name" => "reviewer" }, JSON.parse(seen.grep(%r{\APOST /agents/publish}).fetch(0).partition("\r\n\r\n").last))
      assert_equal({ "name" => "reviewer" }, JSON.parse(seen.grep(%r{\APOST /agents/rm}).fetch(0).partition("\r\n\r\n").last))
    end

    def test_the_verbs_refuse_a_missing_name_and_an_unknown_verb
      assert_equal "agents publish needs NAME", assert_raises(Rho::Error) { agents("publish", nil) }.message
      assert_equal "agents rm needs NAME", assert_raises(Rho::Error) { agents("rm", nil) }.message
      assert_match(/\Aagents takes sync, publish or rm: /, assert_raises(Rho::Error) { agents("push", "x") }.message)
    end
  end
end
