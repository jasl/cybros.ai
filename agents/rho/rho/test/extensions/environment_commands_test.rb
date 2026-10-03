require "test_helper"

# THE VERBS THAT MAKE A CAPABILITY DEBUGGABLE BEFORE ITS UI EXISTS. A
# control route with no way to drive it from a terminal cannot be
# exercised until somebody builds a screen for it, which inverts the order
# these are meant to be built in.
class EnvironmentCommandsTest < Minitest::Test
  include RhoTest::CliHarness

  def env(directory = nil, clear: false) = Rho::Extensions::Environment::Commands.env(cli, [directory], { clear: clear })

  def runner = Rho::Extensions::Environment::Commands.runner(cli, [], {})

  def test_env_reads_where_the_tools_are_pointed
    stated = File.join(@root, "src")
    FileUtils.mkdir_p(stated)
    boot(config: Rho::Config.from_hash("tools_root" => stated))

    environment = env

    assert_equal stated, environment.fetch("root")
    assert_equal "settings", environment.fetch("source")
    assert_includes @out.string, stated
    assert_includes @out.string, "source:    settings"
  end

  def test_env_with_a_directory_moves_the_tools
    moved = File.join(@root, "elsewhere")
    FileUtils.mkdir_p(moved)
    boot

    environment = env(moved)

    assert_equal moved, environment.fetch("root")
    assert_equal "api", environment.fetch("source")
    assert_equal moved, env.fetch("root"), "and it stuck"
  end

  def test_env_clear_falls_back_to_the_settings
    settings_root = File.join(@root, "from-settings")
    api_root = File.join(@root, "from-api")
    [settings_root, api_root].each { |path| FileUtils.mkdir_p(path) }
    boot(config: Rho::Config.from_hash("tools_root" => settings_root))

    env(api_root)
    environment = env(clear: true)

    assert_equal settings_root, environment.fetch("root")
  end

  # A REFUSAL IS A SENTENCE, not a backtrace — the reader is a person at a
  # terminal.
  def test_a_directory_that_is_not_one_is_one_sentence
    boot

    error = assert_raises(Rho::Error) { env(File.join(@root, "nope")) }
    assert_includes error.message, "is not a directory"
  end

  def test_a_daemon_that_is_not_running_says_so_rather_than_failing_obscurely
    error = assert_raises(Rho::Error) { env }
    assert_includes error.message, "rho server"
  end

  def test_runner_reports_nothing_started_before_a_workspace_is_adopted
    boot

    assert_nil runner
    assert_includes @out.string, "no workspace adopted"
  end

  # THE TWO CALLS ARE NAMED PRIMITIVES NOW: the verb reads and moves the tools through
  # `Core#environment` / `Core#repoint_environment`, never a raw
  # `core.get`/`core.post` behind a route literal — the ACP surface binds
  # a session's cwd through the same two doors.
  def test_the_verbs_reach_the_environment_through_the_named_primitives_alone
    source = File.read(File.expand_path("../../lib/rho/extensions/environment.rb", __dir__), encoding: "UTF-8")
    code = source.lines.map { |line| line.chomp.sub(/(?<!["'\\])#.*\z/, "") }.join("\n")
    refute_match(%r{\bcore\.(get|post|put)\([^)]*"/environment"}, code,
      "no raw call behind the two routes: the capability is the core's (`/runner` stays the extension's own read)")
    assert_match(/core\.environment\b/, code)
    assert_match(/core\.repoint_environment\(/, code)
  end
end
