require "test_helper"
require "open3"
require "stringio"

# THE EXE'S ARGV:
# the flags, `connect`, an unknown word → the usage on stderr, exit 1 —
# never 0, never 2.
class AcpExeTest < Minitest::Test
  Cli = Rho::Acp::Agent::Cli

  def test_the_flags_parse_in_both_spellings_with_their_defaults
    options = Cli.parse(%w[--mode ask --model=openrouter/m --runner exr_1])
    assert_equal ["ask", "openrouter/m", "exr_1", nil], [options.mode, options.model, options.runner, options.word]

    defaults = Cli.parse([])
    assert_equal ["bypass", nil, nil, nil], [defaults.mode, defaults.model, defaults.runner, defaults.word]
    assert_equal "connect", Cli.parse(%w[connect --mode rules]).word
  end

  def test_a_bad_mode_a_missing_value_an_unknown_flag_and_an_unknown_word_are_usage_errors
    [%w[--mode nope], %w[--model], %w[--model --runner x], %w[--verbose], %w[serve], %w[connect connect]].each do |argv|
      assert_raises(Cli::UsageError, argv.inspect) { Cli.parse(argv) }
    end
  end

  def test_run_prints_the_usage_on_stderr_and_exits_1
    err = StringIO.new
    assert_equal 1, Cli.run(%w[bogus], err: err)
    assert_includes err.string, "rho-acp: unknown word \"bogus\""
    assert_includes err.string, "usage: rho-acp [--mode bypass|ask|rules]"
    assert_includes err.string, "rho-acp connect"
  end

  def test_the_exe_itself_exits_1_on_an_unknown_word_with_nothing_on_stdout
    stdout, stderr, status = Open3.capture3(RhoAcpTest::CHILD_BUNDLE_ENV, Gem.ruby, "-rbundler/setup", RhoAcpTest::EXE, "bogus")

    assert_equal 1, status.exitstatus
    assert_equal "", stdout
    assert_includes stderr, "usage: rho-acp"
  end

  # The terminal's `connect` composition stood in for: what `rho-acp
  # connect` builds and runs, and how its outcome becomes the exit.
  def with_terminal(fake)
    homes = []
    original = Rho::Cli::Terminal.method(:new)
    Rho::Cli::Terminal.define_singleton_method(:new) do |home:, **|
      homes << home
      fake
    end
    yield homes
  ensure
    Rho::Cli::Terminal.define_singleton_method(:new, original)
  end

  # A fake terminal: `core` answers the connected question (`running_daemon`
  # nil = no daemon, so the ceremony runs; a daemon with an active status
  # over a stored pointer = connected), `connect` is the ceremony.
  def terminal(daemon: nil, connected: false, &ceremony)
    fake = Object.new
    core = Object.new
    core.define_singleton_method(:running_daemon) { daemon }
    core.define_singleton_method(:stored_connection) { connected ? { "agent" => "cnn_1" } : nil }
    core.define_singleton_method(:status_document) { |_daemon| { "state" => connected ? "active" : "disconnected" } }
    fake.define_singleton_method(:core) { core }
    fake.define_singleton_method(:connect) { (@ran = true) && ceremony&.call }
    fake.define_singleton_method(:ran?) { @ran == true }
    fake
  end

  def test_connect_runs_the_terminals_ceremony_and_exits_by_its_outcome
    connected = terminal
    err = StringIO.new
    with_terminal(connected) do |homes|
      assert_equal 0, Cli.run(%w[connect], env: { "RHO_NEXUS_URL" => "https://nexus.example", "RHO_HOME" => Dir.mktmpdir("rho-acp-connect") }, err: err)
      assert_kind_of Rho::Home, homes.first
    end
    assert connected.ran?

    refusing = terminal { raise(Rho::ConnectionError, "the connection is no longer in flight") }
    with_terminal(refusing) do
      assert_equal 1, Cli.run(%w[connect], env: { "RHO_NEXUS_URL" => "https://nexus.example" }, err: err)
    end
    assert_includes err.string, "rho-acp: the connection is no longer in flight"
  end

  # a connected home exits 0 at once — no ceremony (the daemon would refuse a second one
  # 409 `already_connected`), one sentence.
  def test_connect_on_a_connected_home_exits_0_at_once_without_a_ceremony
    already = terminal(daemon: { "endpoint" => "http://127.0.0.1:1" }, connected: true)
    err = StringIO.new
    with_terminal(already) do
      assert_equal 0, Cli.run(%w[connect], env: { "RHO_NEXUS_URL" => "https://nexus.example" }, err: err)
    end
    refute already.ran?, "no ceremony on a connected home"
    assert_includes err.string, "rho-acp: #{Cli::ALREADY_CONNECTED}"

    # A daemon that runs DISCONNECTED (no pointer) is the ceremony as before.
    disconnected = terminal(daemon: { "endpoint" => "http://127.0.0.1:1" }, connected: false)
    with_terminal(disconnected) do
      assert_equal 0, Cli.run(%w[connect], env: { "RHO_NEXUS_URL" => "https://nexus.example" }, err: err)
    end
    assert disconnected.ran?
  end
end
