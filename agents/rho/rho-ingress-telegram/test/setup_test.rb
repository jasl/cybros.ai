require "test_helper"
require "rho/ingress-telegram/setup"
require "tmpdir"
require "fileutils"
require "stringio"

class TelegramSetupTest < Minitest::Test
  TOKEN = "synthetic-setup-secret".freeze
  CONNECTION = "019a1111-2222-7333-8444-555555555551".freeze
  BOT = "019a1111-2222-7333-8444-555555555552".freeze

  class TerminalIO < StringIO
    def tty? = true
    def noecho = yield self
  end

  class Client
    attr_reader :calls, :closed
    attr_accessor :bot_id, :failure
    def initialize
      @calls, @closed, @bot_id = [], false, 42
    end
    def call(method)
      @calls << method
      raise failure if failure

      { "id" => bot_id, "username" => "setup_test_bot" }
    end
    def close = @closed = true
  end

  class LiveCore < Rho::Core
    attr_reader :changes
    attr_accessor :bots, :configuration, :malformed
    def initialize(home:)
      super
      @changes = []
      @configuration = {}
      @bots = [{ "public_id" => BOT, "name" => "helper", "home_workspace_public_id" => "workspace-home" }]
    end
    def running_daemon = :test_daemon
    def require_daemon = :test_daemon
    def get(_daemon, path)
      raise "Unexpected read #{path}" unless path == "/agents"

      Struct.new(:code, :body).new("200", malformed ? "not JSON" : JSON.generate("bots" => bots))
    end
    def telegram_connection(connection_public_id:)
      { "connection" => { "public_id" => connection_public_id, "bot" => { "id" => 42 } } }
    end
    def telegram_settings(agent_public_id:)
      raise "Unexpected Bot" unless agent_public_id == BOT

      { "configuration" => configuration }
    end
    def configure_extension(id, operations:, enabled:)
      @changes << [:plugin, id, operations, enabled]
      { "saved" => true, "applied" => true }
    end
    def configure_telegram_connection(changes, connection_public_id:)
      @changes << [:connection, connection_public_id, changes]
      { "connection" => { "public_id" => connection_public_id || CONNECTION } }
    end
    def configure_telegram(changes, agent_public_id:)
      @changes << [:bot, agent_public_id, changes]
      { "saved" => true, "applied" => true }
    end
  end

  def setup
    @root = Dir.mktmpdir("rho-telegram-setup")
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
    @output, @client, @tokens = TerminalIO.new, Client.new, []
  end

  def teardown = FileUtils.remove_entry(@root)

  def test_offline_setup_saves_only_a_connection_without_polling_or_secret_output
    @home.write_setting("plugins", { "rho.web_tools" => { "enabled" => true } })
    @home.write_setting("default_model", "provider/model")
    assert run_setup("\n #{TOKEN} \ny\n")

    assert_equal ["getMe"], @client.calls
    assert @client.closed
    assert_equal [TOKEN], @tokens
    rows = configuration.fetch("connections")
    assert_equal 1, rows.length
    assert_match Rho::IngressTelegram::Settings::UUID, rows.keys.first
    assert_equal TOKEN, rows.values.first.fetch("token")
    assert_equal "Telegram", rows.values.first.fetch("name")
    assert_empty configuration.fetch("bots", {})
    assert_equal 0o600, File.stat(@home.settings_path).mode & 0o777
    assert_equal 0o700, File.stat(@root).mode & 0o777
    assert config.dig("plugins", "rho.web_tools", "enabled")
    assert_equal "provider/model", config.fetch("default_model")
    refute_includes @output.string, TOKEN
    assert_includes @output.string, "--finish"
    refute_path_exists File.join(@root, "telegram", "state.json")
  end

  def test_failed_verification_and_declined_confirmation_do_not_save
    @client.failure = Rho::IngressTelegram::Client::Unavailable.new(reason: :transport, ambiguous: false)
    assert_raises(Rho::Error) { run_setup("\n#{TOKEN}\n") }
    assert @client.closed
    refute_path_exists @home.settings_path
    @client.failure = nil
    assert_raises(CybrosControl::Cancelled) { run_setup("\n#{TOKEN}\nn\n") }
    refute_path_exists @home.settings_path
  end

  def test_finish_binds_an_explicit_group_target_to_an_existing_bot_without_verifying_or_polling
    write_connection
    core = LiveCore.new(home: @home)
    assert run_setup("-10\n4\n007\ny\n", finish: true, core: core)

    assert_equal [[:bot, BOT, { "enabled" => true, "connection_public_id" => CONNECTION,
      "target" => { "chat_id" => "-10", "topic_id" => 4 }, "owner_id" => "7" }]], core.changes
    assert_empty @client.calls
    assert_empty @tokens
    assert_equal TOKEN, configuration.dig("connections", CONNECTION, "token")
    refute_includes @output.string, TOKEN
    assert_includes @output.string, "workspace-home"
  end

  def test_finish_validates_target_and_owner_and_blank_topic_selects_the_whole_group
    write_connection
    core = LiveCore.new(home: @home)
    core.configuration = { "target" => { "chat_id" => "-10", "topic_id" => 4 } }
    assert run_setup("0\nchat\n-10\n\nalice\n0\n-1\n7,8\n7\ny\n", finish: true, core: core)

    assert_equal({ "chat_id" => "-10", "topic_id" => nil }, core.changes.last.last.fetch("target"))
    assert_equal "7", core.changes.last.last.fetch("owner_id")
    assert_includes @output.string, "nonzero numeric Telegram chat ID"
    assert_includes @output.string, "positive numeric Telegram ID"
  end

  def test_live_setup_saves_through_connection_management_and_then_binds_a_private_target
    write_connection
    core = LiveCore.new(home: @home)
    assert run_setup("1\n\ny\ny\n7\n7\ny\n", core: core)

    assert_equal ["getMe"], @client.calls
    assert_equal [:connection, CONNECTION, { "name" => "Shared", "enabled" => true, "token" => TOKEN }], core.changes.first
    assert_equal [:bot, BOT, { "enabled" => true, "connection_public_id" => CONNECTION,
      "target" => { "chat_id" => "7", "topic_id" => nil }, "owner_id" => "7" }], core.changes.last
    refute core.changes.any? { |row| row.first == :plugin }, "live credential writes use the physical identity admission route"
  end

  def test_new_live_connection_enables_the_management_surface_before_saving
    core = LiveCore.new(home: @home)
    core.bots = []
    assert run_setup("\n#{TOKEN}\ny\n", core: core)

    assert_equal [:plugin, Rho::IngressTelegram::NAME, [], true], core.changes.first
    assert_equal :connection, core.changes.last.first
    assert_equal 2, core.changes.length
    assert_includes @output.string, "Create a Bot"
  end

  def test_declining_target_does_not_change_the_connection_or_bot
    write_connection
    core = LiveCore.new(home: @home)
    before = File.read(@home.settings_path)
    assert_raises(CybrosControl::Cancelled) { run_setup("7\n7\nn\n", finish: true, core: core) }
    assert_empty core.changes
    assert_equal before, File.read(@home.settings_path)
  end

  def test_finish_requires_a_live_daemon_and_a_bot_home
    write_connection
    error = assert_raises(Rho::Error) { run_setup("", finish: true) }
    assert_includes error.message, "Start rho"
    core = LiveCore.new(home: @home)
    core.bots.first["home_workspace_public_id"] = nil
    error = assert_raises(Rho::Error) { run_setup("", finish: true, core: core) }
    assert_includes error.message, "Home Workspace"
    assert_empty core.changes
  end

  def test_malformed_bot_inventory_and_noninteractive_input_are_not_treated_as_empty_setup
    write_connection
    core = LiveCore.new(home: @home)
    core.malformed = true
    assert_raises(Rho::ConnectionError) { run_setup("", finish: true, core: core) }
    assert_raises(Rho::Error) { run_setup("", finish: true, interactive: false, core: core) }
    assert_empty core.changes
    assert_empty @client.calls
  end

  def test_setup_does_not_change_durable_access_or_pending_updates
    state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home, key: "bot:#{BOT}"))
    state.change do |document|
      document["access"] = { "allowed_users" => ["8"], "allowed_chats" => ["-10"], "ignored_users" => ["9"] }
      document["pending_update"] = { "update" => { "update_id" => 12 } }
    end
    before = state.read
    assert run_setup("\n#{TOKEN}\ny\n")
    assert_equal before, state.read
  end

  private

    def run_setup(input, finish: false, interactive: true, core: nil)
      input = interactive ? TerminalIO.new(input) : StringIO.new(input)
      prompt = CybrosControl::Prompt.new(input: input, output: @output)
      Rho::IngressTelegram::Setup.new(home: @home, prompt: prompt, core: core,
        clients: ->(token) { @tokens << token; @client }).run(finish: finish)
    end

    def config = Rho::Config.read(@home.settings_path)
    def configuration = config.fetch("plugins").fetch(Rho::IngressTelegram::NAME).fetch("configuration")

    def write_connection
      @home.write_setting("plugins", { Rho::IngressTelegram::NAME => { "enabled" => true, "configuration" => {
        "connections" => { CONNECTION => { "name" => "Shared", "token" => TOKEN, "enabled" => true } },
      } } })
    end
end
