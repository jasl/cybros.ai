require "test_helper"

# WHERE THE TOOLS ARE POINTED (the UI's chip), with the extension loaded
# alone: read back, moved, cleared, and
# refused in the order the verb always refused. The verbs are in
# environment_commands_test.
class EnvironmentExtensionTest < Minitest::Test
  include RhoTest::DaemonHarness

  def boot(extensions: [Rho::Extensions::Environment], config: agent_mode, **options) = super(extensions:, config:, **options)

  # POINTING A RUNNER AT A PROJECT is the act the whole environment story
  # turns on. Telling a model where it is does not make it work there — a
  # live model, told exactly that, wrote a relative path anyway — so this
  # is what makes the statement true.
  def test_the_environment_reads_back_what_the_tools_are_pointed_at
    stated = File.join(@root, "src")
    FileUtils.mkdir_p(stated)
    daemon = boot(config: agent_mode("tools_root" => stated))

    document = JSON.parse(request(daemon, :get, "/environment",
      token: bearer(daemon)).body).fetch("environment")

    assert_equal stated, document.fetch("root")
    assert_equal "settings", document.fetch("source"),
      "a UI needs to tell a stated value from a default"
  end

  def test_setting_it_moves_the_tools_and_survives_as_the_daemons_own_file
    moved = File.join(@root, "elsewhere")
    FileUtils.mkdir_p(moved)
    daemon = boot

    response = request(daemon, :post, "/environment",
      token: bearer(daemon), body: { root: moved })

    assert_equal "200", response.code
    document = JSON.parse(response.body).fetch("environment")
    assert_equal moved, document.fetch("root")
    assert_equal "api", document.fetch("source")
    assert_equal moved, daemon.context.tool_env.root, "the tools actually moved"

    # The daemon's own file, beside the binding — settings.json belongs to
    # the operator and the daemon never writes it.
    assert_equal moved, Rho::StateFile.new(daemon.home.environment_path).read.fetch("root")
  end

  # `{"root": null}` clears back to the settings file, which is how a UI
  # offers "reset" without a second verb.
  def test_clearing_it_falls_back_to_the_settings
    settings_root = File.join(@root, "from-settings")
    api_root = File.join(@root, "from-api")
    [settings_root, api_root].each { |path| FileUtils.mkdir_p(path) }
    daemon = boot(config: agent_mode("tools_root" => settings_root))

    request(daemon, :post, "/environment", token: bearer(daemon), body: { root: api_root })
    response = request(daemon, :post, "/environment", token: bearer(daemon), body: { root: nil })

    document = JSON.parse(response.body).fetch("environment")
    assert_equal settings_root, document.fetch("root")
    assert_equal "settings", document.fetch("source")
  end

  def test_a_directory_that_is_not_one_is_refused_rather_than_created
    daemon = boot

    response = request(daemon, :post, "/environment",
      token: bearer(daemon), body: { root: File.join(@root, "nope") })

    assert_equal "422", response.code
    assert_equal "not_a_directory", JSON.parse(response.body).dig("error", "code")
  end

  def test_the_environment_is_authenticated_like_every_other_control_route
    daemon = boot
    assert_equal "401", request(daemon, :get, "/environment").code
    assert_equal "401", request(daemon, :post, "/environment", body: { root: @root }).code
  end

  # THE 409 IS RETIRED: a move
  # while a tool call runs rebuilds placement zero and nothing else — the
  # in-flight call keeps the env it was built on, and the runner is never
  # rebuilt — so the directory is judged at once, work or no work.
  def test_a_move_with_work_in_flight_is_judged_on_the_directory_alone
    daemon = one_shot_ready(boot)
    about = daemon.lineage.credentials
    runner = Object.new
    runner.define_singleton_method(:snapshot) { Struct.new(:in_flight).new(1) }
    runner.define_singleton_method(:stop) { nil }
    assert daemon.lineage.reserve_runner(about)
    assert daemon.lineage.install_runner(about, runner, nil)
    before = daemon.context.tool_env
    moved = File.join(@root, "elsewhere")
    FileUtils.mkdir_p(moved)

    response = request(daemon, :post, "/environment", token: bearer(daemon), body: { root: File.join(@root, "nope") })
    assert_equal "422", response.code
    assert_equal "not_a_directory", JSON.parse(response.body).dig("error", "code")

    response = request(daemon, :post, "/environment", token: bearer(daemon), body: { root: moved })
    assert_equal "200", response.code, response.body
    assert_equal moved, daemon.context.tool_env.root, "placement zero moved"
    refute_same before, daemon.context.tool_env, "rebuilt, never mutated: the call in flight keeps its env"
    assert_same runner, daemon.lineage.runner, "the runner is not rebuilt"
  end
end
