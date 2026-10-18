require "test_helper"
require "cgi/escape"
require "stringio"
require "tmpdir"
require "rho/cli/setup"
require "rho/ingress-telegram/setup"
require "support/actor_provisioning"
require "support/ceremony"
require "support/mock_llm/app"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"
require "support/telegram_http_server"

# Terminal answers and external provider/Telegram IO are deterministic. The wizard,
# Human settings API, device pairing, live configuration, Telegram polling and
# model request use shipped product paths against isolated synthetic services.
class RhoSetupTest < Minitest::Test
  PROVIDER = "e2e-key".freeze
  MODEL = "e2e-key/mock-keyed-text".freeze
  CONNECTION_NAME = "Setup Telegram".freeze
  BOT_TOKEN = E2E::TelegramHttpServer::TOKEN

  class Answers
    attr_reader :output, :secrets, :kept_key

    def initialize(people, owner: "101")
      @people = people
      @owner = owner
      @output = StringIO.new
      @secrets = []
      @kept_key = false
    end

    def interactive? = true
    def say(text = "") = @output.puts(text)

    def ask(label, default: nil, secret: false)
      @secrets << label if secret
      case label
      when "#{PROVIDER} API key" then E2E::MockLLM::App::API_KEY
      when "Connection name" then CONNECTION_NAME
      when "Bot token" then BOT_TOKEN
      when "Telegram chat ID", "Bot owner numeric Telegram user ID" then @owner
      else raise "Unexpected setup question: #{label} (#{default})"
      end
    end

    def choose(label, choices:, default: 0)
      case label
      when "Choose a model provider"
        choices.index { |choice| choice.start_with?("#{PROVIDER} (") } or raise "Missing synthetic provider"
      when "Default model"
        choices.index(MODEL) or raise "Missing configured model"
      when "An API key is already configured for #{PROVIDER}."
        @kept_key = true
        choices.index("Keep existing key") or raise "Missing keep choice"
      when "Telegram Connection"
        choices.index { |choice| choice.start_with?("#{CONNECTION_NAME} (") } or raise "Missing saved Connection"
      else raise "Unexpected setup choices: #{label} (#{default})"
      end
    end

    def confirm(label, default: true)
      case label
      when "Configure another provider?" then false
      when "Configure a model provider as a Nexus administrator?", "Set up Telegram messaging?",
           "Keep the current Telegram bot token?", "Save this Telegram Connection?", "Save this Bot target?"
        true
      else raise "Unexpected setup confirmation: #{label} (#{default})"
      end
    end
  end

  def setup
    @base_url = E2E.base_url
    @people = E2E::ActorProvisioning.world(@base_url)
    # This journey can run first in its world; found the owner through the
    # public browser ceremony before attempting password authentication.
    @people.owner_public_id
    E2E::SessionSignInBudget.consume
    grant = CybrosAgent::Platform::Sessions.new(base_url: @base_url).create(email: @people.owner_email, password: @people.owner_password)
    E2E::SecretHygiene.register(grant.token)
    @operator = CybrosAgent::PlatformClient.new(base_url: @base_url, credential: grant.token)
    reset_provider
    @root = Dir.mktmpdir("rho-setup-e2e")
    @project = File.join(@root, "project")
    @home = Rho::Home.resolve(base_url: @base_url, root: File.join(@root, "home"))
    FileUtils.mkdir_p([@home.root, @project])
    File.write(@home.settings_path, JSON.generate("settings_version" => 1, "plugins" => {}, "adaptations" => "default"), perm: 0o600)
    @telegram = E2E::TelegramHttpServer.new.start
    E2E::SecretHygiene.register(BOT_TOKEN)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home.root, tools_root: @project,
      env: { "RHO_MODE" => "full", "RHO_DEFAULT_MODEL" => nil,
             "E2E_TELEGRAM_URL" => @telegram.url,
             "RUBYOPT" => "-r#{File.expand_path("../support/telegram_http_prelude.rb", __dir__)}" })
    @daemon.start
    @people.with_owner_browser do |actor|
      E2E::Ceremony.confirm(actor: actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    end
    @daemon.await("rho workspace adoption") { @daemon.status.dig("workspace", "state") == "adopted" }
    @output = StringIO.new
    E2E.hosts.start
  end

  def teardown
    unless passed? || !@daemon
      directory = File.expand_path("../artifacts/rho_setup/#{name}-#{Process.pid}", __dir__)
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "rho.log"), E2E::SecretHygiene.redact(@daemon.log_text))
    end
  ensure
    if (result = @daemon&.dispose_connection)
      output, status = result
      assert_predicate status, :success?, output
    end
    @telegram&.stop
    if @operator
      reset_provider
      @operator.session.revoke
    end
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_setup_configures_provider_default_model_and_private_telegram_then_can_be_repeated
    assert_equal "USD", @operator.cost_unit.fetch.cost_unit, "browser founding configures the cost unit before rho setup"
    refute provider.fetch.configured?
    refute provider.fetch.enabled?
    first = run_setup
    refute_includes first.secrets, "Nexus password", "provider setup uses the Human OAuth login from connection"
    assert_includes first.secrets, "#{PROVIDER} API key"
    assert_includes first.secrets, "Bot token"
    assert provider.fetch.configured?
    assert provider.fetch.enabled?
    settings = Rho::Config.read(@home.settings_path)
    assert_equal MODEL, settings.fetch("default_model")
    assert_equal "default", settings.fetch("adaptations"), "unrelated settings survive"
    assert settings.dig("plugins", "rho.ingress_telegram", "enabled")
    configuration = telegram_configuration(settings)
    connections = configuration.fetch("connections")
    assert_equal 1, connections.length
    @connection_id = connections.keys.fetch(0)
    assert_equal BOT_TOKEN, connections.fetch(@connection_id).fetch("token")
    assert_empty configuration.fetch("bots", {}), "a Connection alone grants nobody a Bot destination"
    assert_empty @daemon.control(:get, "/agents").fetch("bots"), "setup does not create conversational identities"
    assert_equal 0, File.stat(@home.settings_path).mode & 0o077
    refute_includes JSON.generate(@daemon.control(:get, "/extensions")), BOT_TOKEN
    refute_includes File.read(@home.settings_path), E2E::MockLLM::App::API_KEY
    assert_operator_login

    assert_equal MODEL, @daemon.control(:get, "/settings").dig("settings", "default_model")
    @telegram.message(id: 1, user: 101, text: "/start")
    @daemon.await("Telegram did not consume the unbound /start update") { connection_status.fetch("offset") == 2 }
    assert_empty @telegram.messages, "an unbound Connection sends no reply"
    created = @daemon.control(:put, "/agents", body: {
      name: "setup-helper", display_name: "Setup helper", description: "Answers the owner's Telegram chat.", audience: "owner",
    })
    @bot_id = created.fetch("agent").fetch("public_id")
    @daemon.control(:put, "/agents/settings", body: {
      agent_public_id: @bot_id, home_workspace_public_id: @daemon.status.fetch("workspace").fetch("public_id"),
    })
    finish = Answers.new(@people)
    assert setup_wizard(finish).run("telegram", finish: true)
    assert_empty finish.secrets, "finishing owner setup does not ask for a token or Human login"
    settings = Rho::Config.read(@home.settings_path)
    bot_settings = telegram_configuration(settings).fetch("bots").fetch(@bot_id)
    assert_equal "101", bot_settings.fetch("owner_id")
    assert_equal @connection_id, bot_settings.fetch("connection_public_id")
    assert_equal({ "chat_id" => "101", "topic_id" => nil }, bot_settings.fetch("target"))
    refute bot_settings.key?("token"), "transport credentials belong to the Connection"
    assert_equal "101", telegram_status.dig("configuration", "owner_id")
    @telegram.message(id: 2, user: 101, text: "/start")
    @daemon.await("the bound Bot did not answer /start in its target") do
      @telegram.messages.any? { |message| message.fetch("chat_id").to_s == "101" && message.fetch("text").include?("/status") }
    end
    @daemon.await("Telegram did not commit the bound /start update") { connection_status.fetch("offset") == 3 }
    @daemon.await_announced(address: "runner")
    output, status = @daemon.cli("run", "!mock reply=#{CGI.escape("onboarding default works")} -- say it",
      "--dir", @project, "--output-format", "json", "--timeout", "60")
    assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
    assert_equal "Mock: onboarding default works", JSON.parse(output).fetch("result").strip

    # Setup must not reset delivery recovery when a person revisits configuration.
    before_state = telegram_status.slice("agent_public_id", "connection_public_id", "chats", "access")
    before_connection = connection_status.slice("public_id", "bot", "offset", "bot_count")
    before_settings = File.read(@home.settings_path)
    before_token = telegram_configuration(settings).fetch("connections").fetch(@connection_id).fetch("token")
    second = run_setup
    assert second.kept_key
    refute_includes second.secrets, "#{PROVIDER} API key"
    refute_includes second.secrets, "Bot token"
    assert_equal before_settings, File.read(@home.settings_path)
    repeated = telegram_configuration(Rho::Config.read(@home.settings_path))
    assert_equal before_token, repeated.fetch("connections").fetch(@connection_id).fetch("token")
    assert_equal [@connection_id], repeated.fetch("connections").keys
    assert_equal [@bot_id], repeated.fetch("bots").keys
    assert_equal [@bot_id], @daemon.control(:get, "/agents").fetch("bots").map { |bot| bot.fetch("public_id") }
    assert_equal before_state, telegram_status.slice("agent_public_id", "connection_public_id", "chats", "access")
    assert_equal before_connection, connection_status.slice("public_id", "bot", "offset", "bot_count")
    assert_equal @daemon.pid, JSON.parse(File.read(File.join(@home.root, "tmp", "announcement.json"))).fetch("pid")
    assert @telegram.calls.any? { |method, _| method == "getMe" }
    refute_includes second.secrets, "Nexus password"
    assert_operator_login
  end

  private

    def provider = @operator.model_providers.provider(PROVIDER)
    def telegram_configuration(settings) = settings.fetch("plugins").fetch("rho.ingress_telegram").fetch("configuration")
    def telegram_status = @daemon.control(:get, "/telegram?agent_public_id=#{@bot_id}")
    def connection_status = @daemon.control(:get, "/telegram/connection?connection_public_id=#{@connection_id}").fetch("connection")

    def reset_provider
      context = provider
      context.remove_api_key if context.fetch.configured?
      lane = context.fetch
      context.disable(expected_lock_version: lane.lock_version) if lane.enabled?
    end

    def run_setup(owner: "101")
      answers = Answers.new(@people, owner: owner)
      assert setup_wizard(answers).run
      [BOT_TOKEN, E2E::MockLLM::App::API_KEY, @people.owner_password].each do |secret|
        refute_includes answers.output.string, secret
        refute_includes @output.string, secret
      end
      answers
    end

    def setup_wizard(answers)
      cli = Rho::Cli::Terminal.new(home: @home, out: @output)
      Rho::Cli::Setup.new(cli: cli, nexus_url: @base_url, public_url: @base_url,
        prompt: answers, env: {}, output: @output, error: @output,
        provider_setup: ->(client:) {
          CybrosControl::Setup.new(url: @base_url, prompt: answers, error: @output, client: client).run
        },
        telegram_setup: ->(finish:) {
          Rho::IngressTelegram::Setup.new(home: @home, prompt: answers, clients: ->(token) {
            assert_equal BOT_TOKEN, token
            Rho::IngressTelegram::Client.new(token: token, url: @telegram.url, poll_timeout: 2)
          }).run(finish: finish)
        })
    end

    def assert_operator_login
      cli = Rho::Cli::Terminal.new(home: @home, out: @output)
      cli.core.with_platform_client do |client|
        assert_equal "owner", client.profile.fetch.member.role
        assert provider.fetch.enabled?
      end
    end
end
