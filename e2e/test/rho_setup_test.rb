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

# Terminal answers and external provider/Telegram IO are deterministic. The wizard,
# Human settings API, device pairing, saved configuration, daemon restart and
# model request use shipped product paths against the isolated Nexus and fake provider.
class RhoSetupTest < Minitest::Test
  PROVIDER = "e2e-key".freeze
  MODEL = "e2e-key/mock-keyed-text".freeze
  BOT_TOKEN = "42:synthetic-onboarding-token".freeze

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
      when "Nexus email" then @people.owner_email
      when "Nexus password" then @people.owner_password
      when "#{PROVIDER} API key" then E2E::MockLLM::App::API_KEY
      when "Bot token" then BOT_TOKEN
      when /Bot owner numeric user ID/ then @owner
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
      else raise "Unexpected setup choices: #{label} (#{default})"
      end
    end

    def confirm(label, default: true)
      case label
      when "Configure another provider?" then false
      when "Configure a model provider as a Nexus administrator?", "Set up Telegram messaging?",
           "Keep the saved Telegram bot token?", "Save Telegram configuration?"
        true
      else raise "Unexpected setup confirmation: #{label} (#{default})"
      end
    end
  end

  class TelegramIdentity
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(method, **)
      raise "Unexpected Telegram IO: #{method}" unless method == "getMe"

      @calls << method
      { "id" => 42, "username" => "onboarding_test_bot", "is_bot" => true }
    end

    def close; end
  end

  class RecordingSessions
    def initialize(url, tokens)
      @client = CybrosAgent::Sessions.new(base_url: url)
      @tokens = tokens
    end

    def create(**attributes)
      E2E::SessionSignInBudget.consume
      grant = @client.create(**attributes)
      @tokens << grant.token
      E2E::SecretHygiene.register(grant.token)
      grant
    end
  end

  def setup
    @base_url = E2E.base_url
    @people = E2E::ActorProvisioning.world(@base_url)
    steward = @people.rho_steward
    E2E::SessionSignInBudget.consume
    grant = CybrosAgent::Sessions.new(base_url: @base_url).create(email: @people.owner_email, password: @people.owner_password)
    E2E::SecretHygiene.register(grant.token)
    @operator = CybrosAgent::PlatformClient.new(base_url: @base_url, credential: grant.token)
    reset_provider
    @root = Dir.mktmpdir("rho-setup-e2e")
    @project = File.join(@root, "project")
    @home = Rho::Home.resolve(base_url: @base_url, root: File.join(@root, "home"))
    FileUtils.mkdir_p([@home.root, @project])
    File.write(@home.settings_path, JSON.generate("extensions" => [], "compose" => "on"))
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home.root, tools_root: @project,
      env: { "RHO_MODE" => "full", "RHO_DEFAULT_MODEL" => nil, "RHO_TELEGRAM_BOT_TOKEN" => nil,
             "RUBYOPT" => "-r#{File.expand_path("../support/telegram_transport_prelude.rb", __dir__)}" })
    @daemon.start
    actor = E2E::StewardSession.actor(base_url: @base_url, human: steward)
    E2E::Ceremony.confirm(actor: actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    @daemon.await("rho workspace adoption") { @daemon.status.dig("workspace", "state") == "adopted" }
    @sessions = []
    @telegram = TelegramIdentity.new
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
    @daemon&.stop
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
    first = run_setup(owner: "")
    assert_includes first.secrets, "Nexus password"
    assert_includes first.secrets, "#{PROVIDER} API key"
    assert_includes first.secrets, "Bot token"
    assert provider.fetch.configured?
    assert provider.fetch.enabled?
    settings = Rho::Config.read(@home.settings_path)
    assert_equal MODEL, settings.fetch("default_model")
    assert_equal "on", settings.fetch("compose"), "unrelated settings survive"
    assert_includes settings.fetch("extensions"), "rho/ingress-telegram"
    assert_nil settings.dig("telegram", "owner_id"), "a token alone grants nobody access"
    assert_equal BOT_TOKEN, Rho::IngressTelegram::TokenFile.new(@home).read
    token_path = File.join(@home.root, "telegram", "token.json")
    assert_equal 0, File.stat(token_path).mode & 0o077
    refute_includes File.read(@home.settings_path), BOT_TOKEN
    refute_includes File.read(@home.settings_path), E2E::MockLLM::App::API_KEY
    assert_sessions_revoked

    @daemon.stop
    @daemon.start
    @daemon.await("rho adopted saved setup") { @daemon.status.dig("workspace", "state") == "adopted" }
    finish = Answers.new(@people)
    assert setup_wizard(finish).run("telegram", finish: true)
    assert_empty finish.secrets, "finishing owner setup does not ask for a token or Human login"
    settings = Rho::Config.read(@home.settings_path)
    assert_equal "101", settings.dig("telegram", "owner_id")
    @daemon.stop
    @daemon.start
    @daemon.await("rho reloaded the Telegram owner") { @daemon.status.dig("workspace", "state") == "adopted" }
    @daemon.await_announced(address: "runner")
    output, status = @daemon.cli("run", "!mock reply=#{CGI.escape("onboarding default works")} -- say it",
      "--dir", @project, "--output-format", "json", "--timeout", "60")
    assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
    assert_equal "Mock: onboarding default works", JSON.parse(output).fetch("result").strip

    # Setup must not reset delivery recovery when a person revisits configuration.
    core = Rho::Core.new(home: @home)
    identity = core.stored_identity(core.stored_connection)
    token = identity.vault.read.fetch("access_token")
    E2E::SecretHygiene.register(token)
    client = CybrosAgent::Client.new(base_url: @base_url, credential: token)
    document = Rho::StoreDocument.new(store: -> { client.profile.store_entries }, namespace: "rho.telegram", key: "state")
    state = Rho::IngressTelegram::State.new(store: document)
    state.consumed(123)
    before_state = state.read
    before_settings = File.read(@home.settings_path)
    before_token = File.read(token_path)
    second = run_setup
    assert second.kept_key
    refute_includes second.secrets, "#{PROVIDER} API key"
    refute_includes second.secrets, "Bot token"
    assert_equal before_settings, File.read(@home.settings_path)
    assert_equal before_token, File.read(token_path)
    assert_equal before_state, state.read
    assert_equal %w[getMe getMe getMe], @telegram.calls
    assert_equal 2, @sessions.length
    assert_sessions_revoked
  end

  private

    def provider = @operator.model_providers.provider(PROVIDER)

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
        provider_setup: -> {
          CybrosControl::Setup.new(url: @base_url, prompt: answers, error: @output,
            sessions: ->(url) { RecordingSessions.new(url, @sessions) }).run
        },
        telegram_setup: ->(finish:) {
          Rho::IngressTelegram::Setup.new(home: @home, prompt: answers, env: {}, clients: ->(token) {
            assert_equal BOT_TOKEN, token
            @telegram
          }).run(finish: finish)
        })
    end

    def assert_sessions_revoked
      @sessions.each do |token|
        client = CybrosAgent::PlatformClient.new(base_url: @base_url, credential: token)
        assert_raises(CybrosAgent::Api::Unauthorized) { client.session.fetch }
      end
    end
end
