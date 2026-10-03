require "test_helper"
require "rho/cli/setup"

class CliSetupTest < Minitest::Test
  class TerminalIO < StringIO
    def tty? = true
    def noecho = yield self
  end

  class Controller
    attr_reader :home, :connections, :workloads
    def initialize(home, rows)
      @home, @rows = home, rows
      @connections, @workloads = [], []
    end
    def config = Rho::Config.load(home.settings_path, env: {})
    def core = self
    def running_daemon = nil
    def stored_connection = nil
    def connect(public_url: nil) = @connections << public_url
    def update_settings(changes) = Rho::Core.new(home: home).update_settings(changes)
    def models(workload: nil)
      @workloads << workload
      @rows
    end
  end

  def setup
    @root = Dir.mktmpdir("rho-setup")
    @home = Rho::Home.resolve(base_url: "http://nexus", root: @root).prepare
    @output = TerminalIO.new
    @providers, @telegrams = [], []
    @cli = Controller.new(@home, [model("paid/tool"), model("free/tool", state: "known_free_candidate"),
      model("unknown/tool", state: "cost_unknown"), model("text/only", tools: false), model("disabled/tool", available: false)])
  end

  def teardown = FileUtils.remove_entry(@root)

  def test_full_setup_preserves_settings_and_selects_only_usable_models
    @home.write_setting("runner", "existing-runner")
    assert wizard("n\nn\n2\n", public_url: "https://nexus.example").run
    assert_equal ["https://nexus.example"], @cli.connections
    assert_equal ["text_generation"], @cli.workloads
    assert_equal "free/tool", settings.fetch("default_model")
    assert_equal "existing-runner", settings.fetch("runner")
    assert_empty @providers
    assert_empty @telegrams
    assert_includes @output.string, "https://nexus.example/setup"
    assert_includes @output.string, "unknown/tool"
    %w[text/only disabled/tool].each { |ref| refute_includes @output.string, ref }
  end

  def test_admin_and_telegram_steps_are_explicit
    assert wizard("y\ny\n1\n").run
    assert_equal [:configured], @providers
    assert_equal [false], @telegrams
    assert_equal 1, @cli.connections.length
  end

  def test_model_section_can_reconfigure_provider_and_keeps_saved_choice
    @home.write_setting("default_model", "free/tool")
    assert wizard("y\n\n").run("model")
    assert_equal "free/tool", settings.fetch("default_model")
    assert_equal [:configured], @providers
    assert_empty @telegrams
  end

  def test_saved_default_can_be_changed_despite_an_environment_seed
    @home.write_setting("default_model", "free/tool")
    assert wizard("n\n1\n", env: { "RHO_DEFAULT_MODEL" => "free/tool" }).run("model")
    assert_equal "paid/tool", settings.fetch("default_model")
    refute_includes @output.string, "overrides settings"
  end

  def test_a_repeat_setup_keeps_the_saved_browser_address
    @home.write_setting("nexus_public_url", "https://public.example/nexus")
    assert wizard("n\n1\n").run("model")
    assert_equal ["https://public.example/nexus"], @cli.connections
    assert_equal "https://public.example/nexus", settings.fetch("nexus_public_url")
  end

  def test_no_models_no_tty_runner_and_invalid_url_fail_without_writing
    @cli = Controller.new(@home, [model("disabled/tool", available: false)])
    assert wizard("n\n").run("model")
    assert_includes @output.string, "/admin/model_providers"
    refute settings.key?("default_model")
    @cli.connections.clear
    noninteractive = Rho::Cli::Setup.new(cli: @cli, input: StringIO.new, output: StringIO.new, env: {})
    assert_raises(Rho::Error) { noninteractive.run }
    assert_raises(Rho::Error) { wizard("", public_url: "file:///tmp/nexus").run("model") }
    @home.write_setting("mode", "runner")
    assert_raises(Rho::Error) { wizard("").run }
    assert_empty @cli.connections
  end

  def test_cancellation_preserves_existing_settings
    @home.write_setting("default_model", "free/tool")
    error = assert_raises(Rho::Error) { wizard("n\n").run("model") }
    assert_includes error.message, "cancelled"
    assert_equal "free/tool", settings.fetch("default_model")
  end

  def test_an_available_model_without_prices_can_be_selected
    @cli = Controller.new(@home, [model("custom/tool", state: "cost_unknown")])
    assert wizard("n\n1\n").run("model")
    assert_equal "custom/tool", settings.fetch("default_model")
    assert_empty @providers
  end

  def test_telegram_ensures_connection_and_finish_skips_model_discovery
    assert wizard("").run("telegram")
    assert wizard("").run("telegram", finish: true)
    assert_equal [false, true], @telegrams
    assert_equal ["http://nexus"], @cli.connections
    assert_empty @cli.workloads
    assert_raises(Rho::Error) { wizard("").run("model", finish: true) }
  end

  private

    def wizard(input, env: {}, public_url: nil)
      Rho::Cli::Setup.new(cli: @cli, input: TerminalIO.new(input), output: @output, error: @output,
        env: env, public_url: public_url, provider_setup: -> { @providers << :configured },
        telegram_setup: ->(finish:) { @telegrams << finish; true })
    end
    def settings = Rho::Config.read(@home.settings_path)
    def model(ref, state: "priced", tools: true, available: true)
      { "ref" => ref, "available" => available, "capabilities" => { "tool_calls" => tools }, "pricing" => { "state" => state } }
    end
end
