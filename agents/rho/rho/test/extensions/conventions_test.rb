require "test_helper"
require "tmpdir"

# THE REPOSITORY'S RULES AS A DESCRIBER: the block rides the environment
# fragments after the built-in tools' own, and a tree with no AGENTS.md
# contributes nothing.
class ConventionsExtensionTest < Minitest::Test
  include RhoTest::DaemonHarness

  def setup
    super
    @dir = Dir.mktmpdir("rho-conventions-ext")
    @api = Rho::Extensions::Api.new(host: RhoTest.host, extension_name: "rho.conventions", source: "<test>")
    Rho::Extensions::Conventions.register(@api)
  end

  def teardown
    super
    FileUtils.rm_rf(@dir)
  end

  def describe(working_directory)
    environment = Rho::Runner::Environment.local(root: @dir, working_directory: working_directory)
    @api.environment_descriptions.map { |description| description.handler.call(environment) }
  end

  def test_it_registers_one_describer_and_nothing_else
    assert_equal 1, @api.environment_descriptions.length
    assert_empty @api.tools
    assert_empty @api.daemon_hooks
    assert_empty @api.commands
  end

  def test_the_block_is_the_files_from_the_working_directory_up_to_the_root
    File.write(File.join(@dir, "AGENTS.md"), "Always run the tests.")
    app = File.join(@dir, "app")
    FileUtils.mkdir_p(app)
    File.write(File.join(app, "CLAUDE.md"), "Prefer small commits.")

    block = describe(app).fetch(0)
    assert_equal Rho::Conventions.block(working_directory: app, root: @dir), block
    assert_operator block.index("Always run the tests."), :<, block.index("Prefer small commits."),
      "general first, nearest last"
    empty = File.join(Dir.mktmpdir("rho-conventions-empty"), "work")
    FileUtils.mkdir_p(empty)
    assert_equal [nil], describe(empty), "a tree with no file says nothing"
  end

  # THE ORDER THE SEED CARRIES: coding, processes, conventions — the join
  # the core made before this was an extension, so the bytes stand.
  def test_the_fragment_follows_the_built_in_describers
    File.write(File.join(@dir, "AGENTS.md"), "Always run the tests.")
    registry = Rho::Extensions.load(host: RhoTest.host).registry
    environment = Rho::Runner::Environment.local(root: @dir, working_directory: @dir)

    fragments = registry.environment_fragments(environment)
    assert_equal %w[rho.coding rho.conventions], fragments.map { |fragment| fragment.fetch("extension") }
    assert fragments.last.fetch("text").start_with?("Repository conventions")
  end

  # LOADED ALONE beside the runner's tools, the block reaches the lead the
  # turn opens with, over the wire.
  def test_loaded_alone_the_block_rides_the_turns_lead
    File.write(File.join(@dir, "AGENTS.md"), "Always run the tests.")
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(extensions: [Rho::Runner::Extensions::Coding, Rho::Extensions::Conventions]), api, identity: RUNNER_IDENTITY)

    response = request(daemon, :post, "/conversations", token: bearer(daemon),
      body: { prompt: "p", model: "dev/mock-text", working_directory: @dir })

    assert_equal "201", response.code, response.body
    lead = api.conversation_inputs.fetch(0).dig("input", "inline", 0, "text")
    assert_includes lead, "Repository conventions"
    assert_includes lead, "Always run the tests."
  end

  def test_assembled_leads_keep_changed_repository_guidance_without_repeating_the_runner_snapshot
    path = File.join(@dir, "AGENTS.md")
    File.write(path, "Run the original checks.")
    registry = Rho::Extensions.load(host: RhoTest.host).registry
    environment = Rho::Runner::Environment.local(root: @dir)
    snapshot = { "fragments" => registry.environment_fragments(environment) }

    lead = Rho::RunDeclaration.lead(registry: registry, environment: environment,
      kernel_environment: true, environment_snapshot: snapshot)
    refute_includes lead, "Run the original checks.", "Nexus already supplies the unchanged snapshot"
    refute_includes lead, "Relative paths resolve against", "Nexus supplies the generic Runner environment"

    File.write(path, "Run the revised checks.")
    changed = Rho::RunDeclaration.lead(registry: registry, environment: environment,
      kernel_environment: true, environment_snapshot: snapshot)
    assert_includes changed, "Run the revised checks.", "the current conversation keeps freshly read repository guidance"
    refute_includes changed, "Run the original checks."
  end

  # THE ONE SENTENCE WHILE A PORT IS LIVE: the lead being rendered has a
  # live file-system port → the describer's fragment ends with the model-facing instruction, after the repository's files or alone when there
  # are none; no port, no sentence; no daemon (a loader with no host
  # tables), no sentence. The instruction text is fixed here,
  # never hand-tuned here.
  def test_the_port_sentence_rides_the_fragment_only_while_the_leads_port_is_live
    tables = Struct.new(:live) { def lead_port? = live }.new(false)
    host = RhoTest.host.with(environments: -> { tables })
    api = Rho::Extensions::Api.new(host: host, extension_name: "rho.conventions", source: "<test>")
    Rho::Extensions::Conventions.register(api)
    environment = Rho::Runner::Environment.local(root: @dir, working_directory: @dir)
    describe = -> { api.environment_descriptions.fetch(0).handler.call(environment) }
    sentence = Rho::Extensions::Conventions::PORT_SENTENCE

    assert_equal "The editor's open buffers are what read, edit and write see; grep, glob, ls and shell commands see " \
                 "the disk — use edit or write for files open in the editor; a shell write to a file with unsaved " \
                 "changes is invisible to read.", sentence
    assert_nil describe.call, "no files, no port: nothing"
    tables.live = true
    assert_equal sentence, describe.call, "no files, a live port: the sentence alone"
    File.write(File.join(@dir, "AGENTS.md"), "Always run the tests.")
    fragment = describe.call
    assert fragment.start_with?("Repository conventions"), fragment
    assert fragment.end_with?("\n\n#{sentence}"), "the sentence closes the fragment:\n#{fragment}"
    tables.live = false
    assert_equal Rho::Conventions.block(working_directory: @dir, root: @dir), describe.call, "the port went: the files alone"
    assert_nil @api.environment_descriptions.fetch(0).handler.call(environment).to_s[sentence],
      "an api with no environment tables never says it"
  end
end
