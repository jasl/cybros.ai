require "test_helper"

class TelegramConfigurationRoutesTest < Minitest::Test
  TOKEN = "synthetic-route-token".freeze
  TOKEN_ENV = "RHO_TELEGRAM_ROUTES_TEST_TOKEN_#{Process.pid}".freeze

  class Client
    attr_reader :calls
    attr_accessor :failure
    def initialize = @calls = []
    def call(method)
      @calls << method
      raise failure if failure

      { "id" => 42, "username" => "synthetic_bot" }
    end
    def close = nil
  end

  def setup
    @directory = Dir.mktmpdir("rho-telegram-routes")
    @home = Rho::Home.resolve(root: @directory, base_url: "https://nexus.example").prepare
    @client = Client.new
    client = @client
    Rho::IngressTelegram::Client.define_singleton_method(:new) { |**| client }
    @daemon = Rho::Daemon.boot(home: @home, extensions: [],
      config: Rho::Config.from_hash("mode" => "agent", "api_only" => true))
    @core = Rho::Core.new(home: @home)
  end

  def teardown
    @daemon&.stop
    Rho::IngressTelegram::Client.singleton_class.remove_method(:new)
    ENV.delete(TOKEN_ENV)
    FileUtils.remove_entry(@directory)
  end

  def test_idle_management_can_enable_edit_disable_and_clear_without_restarting
    assert_equal "disabled", @core.telegram_settings.fetch("connection")
    assert_equal({ "saved" => true }, @core.configure_telegram("enabled" => true, "token" => TOKEN, "owner_id" => "7"))
    enabled = @core.telegram_settings
    assert enabled.fetch("enabled")
    assert_equal "waiting_for_nexus", enabled.fetch("connection")
    assert_equal "7", enabled.dig("configuration", "owner_id")
    assert_equal({ "present" => true, "source" => "saved" }, enabled.fetch("token"))
    assert_nil enabled.fetch("access")
    refute_includes JSON.generate(enabled), TOKEN
    refute_includes File.read(@home.settings_path), TOKEN
    assert_equal ["getMe"], @client.calls

    @core.configure_telegram("owner_id" => "8", "stale_after" => 30, "speech_model" => "provider/speech")
    assert_equal "8", @core.telegram_settings.dig("configuration", "owner_id")
    assert_equal ["getMe"], @client.calls
    @core.configure_telegram("enabled" => false, "token" => nil)
    disabled = @core.telegram_settings
    refute disabled.fetch("enabled")
    assert_equal "disabled", disabled.fetch("connection")
    assert_equal({ "present" => false, "source" => "none" }, disabled.fetch("token"))
    assert_equal "", Rho::IngressTelegram::TokenFile.new(@home).read
  end

  def test_saved_token_can_be_replaced_with_the_environment_fallback
    ENV[TOKEN_ENV] = "synthetic-environment-token"
    @core.configure_telegram("enabled" => true, "token" => TOKEN, "token_env" => TOKEN_ENV)
    @core.configure_telegram("token" => nil)
    assert_equal "environment", @core.telegram_settings.dig("token", "source")
    assert_equal "", Rho::IngressTelegram::TokenFile.new(@home).read
    assert_equal ["getMe", "getMe"], @client.calls
  end

  def test_refused_token_and_invalid_settings_preserve_previous_configuration
    @core.configure_telegram("enabled" => true, "token" => TOKEN, "owner_id" => "7")
    before = @core.telegram_settings
    saved = File.read(@home.settings_path)
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 401, description: "never expose #{TOKEN}")
    error = assert_raises(Rho::Core::Refused) { @core.configure_telegram("token" => "replacement") }
    assert_equal 422, error.status
    refute_includes error.message, TOKEN
    assert_equal TOKEN, Rho::IngressTelegram::TokenFile.new(@home).read
    assert_equal saved, File.read(@home.settings_path)
    assert_equal before, @core.telegram_settings
    error = assert_raises(Rho::Core::Refused) { @core.configure_telegram("owner_id" => "alice") }
    assert_equal 400, error.status
    assert_equal saved, File.read(@home.settings_path)
  end

  def test_missing_profile_is_unavailable_without_fabricating_an_empty_access_list
    error = assert_raises(Rho::Core::Refused) do
      @core.change_telegram_access(list: "allowed_users", action: "add", id: "7")
    end
    assert_equal 409, error.status
    assert_nil @core.telegram_settings.fetch("access")
  end

  def test_credential_write_failure_keeps_the_previous_active_configuration
    @core.configure_telegram("enabled" => true, "token" => TOKEN, "owner_id" => "7")
    before, saved = @core.telegram_settings, File.read(@home.settings_path)
    original = Rho::IngressTelegram::TokenFile.instance_method(:write)
    Rho::IngressTelegram::TokenFile.remove_method(:write)
    Rho::IngressTelegram::TokenFile.define_method(:write) { |_token| raise Rho::StateError, "credential write failed" }

    error = assert_raises(Rho::Core::Refused) { @core.configure_telegram("token" => "replacement", "owner_id" => "8") }

    assert_equal 500, error.status
    assert_equal before, @core.telegram_settings
    assert_equal saved, File.read(@home.settings_path)
    assert_equal TOKEN, Rho::IngressTelegram::TokenFile.new(@home).read
  ensure
    if original
      Rho::IngressTelegram::TokenFile.remove_method(:write)
      Rho::IngressTelegram::TokenFile.define_method(:write, original)
    end
  end

  def test_post_save_application_failure_reports_saved_truthfully
    context = Struct.new(:home, :config).new(@home, Rho::Config.from_hash("mode" => "agent"))
    context.define_singleton_method(:update_settings) do |patch, before_save:|
      before_save.call
      home.write_settings(patch)
      raise Rho::Settings::ApplyError, "Settings were saved, but applying them failed."
    end
    coordinator = Struct.new(:bot_id).new(nil)
    request = Protocol::HTTP::Request["POST", "/telegram/configuration",
      { "content-type" => "application/json" }, [JSON.generate("token" => TOKEN, "enabled" => true)]]
    status, document = Rho::IngressTelegram.configure(request, context, coordinator).to_a
    assert_equal 503, status
    assert_equal "settings_apply_failed", document.dig(:error, :code)
    assert_equal true, document.dig(:error, :saved)
    assert_equal TOKEN, Rho::IngressTelegram::TokenFile.new(@home).read
    refute_includes JSON.generate(document), TOKEN
  end
end
