require "test_helper"
require "rho/ingress-telegram/setup"
require "tmpdir"
require "fileutils"
require "stringio"

class TelegramSetupTest < Minitest::Test
  TOKEN = "synthetic-setup-secret".freeze
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
    def call(method, params = {}, poll: false)
      @calls << [method, params, poll]
      raise failure if failure

      { "id" => bot_id, "username" => "setup_test_bot" }
    end
    def close = @closed = true
  end

  def setup
    @root = Dir.mktmpdir("rho-telegram-setup")
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
    @output, @client, @tokens = TerminalIO.new, Client.new, []
  end
  def teardown = FileUtils.remove_entry(@root)

  def test_new_token_is_private_and_only_get_me_is_used
    @home.write_setting("extensions", ["rho/web-tools"])
    @home.write_setting("default_model", "provider/model")
    assert run_setup(" #{TOKEN} \n7\ny\n")
    assert_equal [["getMe", {}, false]], @client.calls
    assert @client.closed
    assert_equal [TOKEN], @tokens
    assert_equal TOKEN, Rho::IngressTelegram::TokenFile.new(@home).read
    assert_equal 0o600, File.stat(File.join(@root, "telegram", "token.json")).mode & 0o777
    assert_equal 0o700, File.stat(File.join(@root, "telegram")).mode & 0o777
    assert_equal "7", values.fetch("owner_id")
    refute values.key?("allowed_users")
    refute values.key?("managers")
    refute values.key?("allowed_chats")
    assert_equal ["rho/web-tools", "rho/ingress-telegram"], config.fetch("extensions")
    assert_equal "provider/model", config.fetch("default_model")
    refute_includes File.read(@home.settings_path), TOKEN
    refute_includes @output.string, TOKEN
    refute_path_exists File.join(@root, "telegram", "state.json")
    assert_equal TOKEN, Rho::IngressTelegram::Settings.new(values, home: @home, env: {}).token
  end

  def test_first_setup_with_a_running_daemon_without_the_telegram_extension
    bundle = File.join(@root, "webui")
    FileUtils.mkdir_p(bundle)
    File.write(File.join(bundle, "index.html"), "<html>rho</html>")
    daemon = Rho::Daemon.boot(home: @home, extensions: [],
      config: Rho::Config.from_hash("mode" => "agent", "webui_root" => bundle))
    core = Rho::Core.new(home: @home)
    response = core.get(core.require_daemon, "/telegram")
    assert_equal "200", response.code
    assert_equal "text/html", response.content_type

    assert run_setup("#{TOKEN}\n7\ny\n")

    assert_equal "7", values.fetch("owner_id")
    assert_equal TOKEN, Rho::IngressTelegram::TokenFile.new(@home).read
    assert_includes config.fetch("extensions"), "rho/ingress-telegram"
    assert_equal [["getMe", {}, false]], @client.calls
  ensure
    daemon&.stop
  end

  def test_first_setup_without_a_webui_accepts_the_missing_telegram_route
    daemon = Rho::Daemon.boot(home: @home, extensions: [],
      config: Rho::Config.from_hash("mode" => "agent", "api_only" => true))

    assert run_setup("#{TOKEN}\n7\ny\n")

    assert_equal "7", values.fetch("owner_id")
    assert_equal TOKEN, Rho::IngressTelegram::TokenFile.new(@home).read
  ensure
    daemon&.stop
  end

  def test_a_loaded_telegram_route_with_malformed_json_still_refuses_setup
    extension = Module.new do
      const_set(:NAME, "rho.broken_telegram_status")
      define_singleton_method(:register) do |api|
        api.register_route("GET", "/telegram") do |*|
          Protocol::HTTP::Response[200, { "content-type" => "application/json" }, ["not JSON"]]
        end
      end
    end
    daemon = Rho::Daemon.boot(home: @home, extensions: [extension],
      config: Rho::Config.from_hash("mode" => "agent", "api_only" => true))

    error = assert_raises(Rho::ConnectionError) { run_setup("#{TOKEN}\n7\ny\n") }

    assert_includes error.message, "not JSON"
    refute_path_exists File.join(@root, "telegram", "token.json")
  ensure
    daemon&.stop
  end

  def test_environment_token_wins_and_blank_owner_input_keeps_the_configured_owner
    Rho::IngressTelegram::TokenFile.new(@home).write("old-secret")
    @home.write_setting("telegram", { "token_env" => "CUSTOM_BOT_TOKEN", "owner_id" => 7 })
    assert run_setup("\n\n", env: { "CUSTOM_BOT_TOKEN" => TOKEN })
    assert_equal [TOKEN], @tokens
    assert_equal "old-secret", Rho::IngressTelegram::TokenFile.new(@home).read
    assert_equal "7", values.fetch("owner_id")
    assert_includes @output.string, "CUSTOM_BOT_TOKEN from the environment"
  end

  def test_failed_verification_and_declined_confirmation_do_not_save
    @client.failure = Rho::IngressTelegram::Client::Unavailable.new(reason: "temporary failure", ambiguous: false)
    assert_raises(Rho::Error) { run_setup("#{TOKEN}\n") }
    assert @client.closed
    refute_path_exists File.join(@root, "telegram", "token.json")
    @client.failure = nil
    assert_raises(CybrosControl::Cancelled) { run_setup("#{TOKEN}\n7\nn\n") }
    refute_path_exists File.join(@root, "telegram", "token.json")
    refute config.key?("telegram")
  end

  def test_another_bot_cannot_replace_the_existing_binding_before_migration
    Rho::StateFile.new(File.join(@root, "telegram", "state.json")).write("bot_id" => "99")
    before = File.read(File.join(@root, "telegram", "state.json"))
    error = assert_raises(Rho::Error) { run_setup("#{TOKEN}\n") }
    assert_includes error.message, "another Telegram bot"
    assert_includes error.message, "Use a different Agent"
    assert_equal before, File.read(File.join(@root, "telegram", "state.json"))
    refute_path_exists File.join(@root, "telegram", "token.json")
  end

  def test_unconfigured_owner_can_be_finished_after_daemon_start
    assert run_setup("#{TOKEN}\n\ny\n")
    assert_nil values.fetch("owner_id")
    assert_includes @output.string, "waiting for a bot owner"
    assert run_setup("alice\n-10\n0\n7,8\n7\ny\n", finish: true)
    assert_equal "7", values.fetch("owner_id")
    assert_equal [TOKEN, TOKEN], @tokens
    assert_equal 2, @client.calls.length
    refute_path_exists File.join(@root, "telegram", "state.json")
    assert_includes @output.string, "positive numeric Telegram user ID"
  end

  def test_finish_no_op_needs_no_terminal_or_network
    assert run_setup("", finish: true, interactive: false)
    assert_empty @client.calls
    assert_equal "", @output.string
    Rho::IngressTelegram::TokenFile.new(@home).write(TOKEN)
    @home.write_setting("extensions", ["rho/ingress-telegram"])
    @home.write_setting("telegram", { "owner_id" => 7 })
    assert run_setup("", finish: true, interactive: false)
    assert_empty @client.calls
    assert_equal "", @output.string
  end

  def test_finish_requires_an_owner_and_preserves_pending_configuration
    Rho::IngressTelegram::TokenFile.new(@home).write(TOKEN)
    @home.write_setting("extensions", ["rho/ingress-telegram"])
    before = File.read(@home.settings_path)
    assert_raises(Rho::Error) { run_setup("\n", finish: true) }
    assert_equal before, File.read(@home.settings_path)
    assert_equal TOKEN, Rho::IngressTelegram::TokenFile.new(@home).read
  end

  def test_setup_does_not_change_runtime_access_lists_or_pending_updates
    state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    state.change do |document|
      document["access"] = { "allowed_users" => ["8"], "allowed_chats" => ["-10"], "ignored_users" => ["9"] }
      document["pending_update"] = { "update" => { "update_id" => 12 } }
    end
    before = state.read
    assert run_setup("#{TOKEN}\n7\ny\n")
    assert_equal before, state.read
    refute_path_exists File.join(@root, "telegram", "state.json")
  end

  private

    def run_setup(input, env: {}, finish: false, interactive: true)
      input = interactive ? TerminalIO.new(input) : StringIO.new(input)
      prompt = CybrosControl::Prompt.new(input: input, output: @output)
      Rho::IngressTelegram::Setup.new(home: @home, prompt: prompt, env: env,
        clients: ->(token) { @tokens << token; @client }).run(finish: finish)
    end
    def config = Rho::Config.read(@home.settings_path)
    def values = config.fetch("telegram")
end
