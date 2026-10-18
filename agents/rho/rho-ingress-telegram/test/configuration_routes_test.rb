require "test_helper"

class TelegramConfigurationRoutesTest < Minitest::Test
  TOKEN = "synthetic-route-token".freeze

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
      config: Rho::Config.from_hash({ "mode" => "agent", "api_only" => true, "plugins" => {
        Rho::IngressTelegram::NAME => { "enabled" => true },
      } }))
    @core = Rho::Core.new(home: @home)
  end

  def teardown
    @daemon&.stop
    Rho::IngressTelegram::Client.singleton_class.remove_method(:new)
    FileUtils.remove_entry(@directory)
  end

  def test_idle_management_can_enable_edit_disable_and_clear_without_restarting
    assert_empty @core.telegram_connections.fetch("connections")
    assert_equal({ "saved" => true, "applied" => true, "restart_required" => false }, configure("enabled" => true, "token" => TOKEN, "name" => "First").slice("saved", "applied", "restart_required"))
    enabled = connection
    assert enabled.fetch("enabled")
    assert_equal "waiting_for_nexus", enabled.fetch("connection")
    assert_equal "First", enabled.fetch("name")
    assert_equal({ "present" => true }, enabled.fetch("token"))
    refute_includes JSON.generate(enabled), TOKEN
    assert_includes File.read(@home.settings_path), TOKEN
    assert_equal ["getMe"], @client.calls

    configure("name" => "Second")
    assert_equal "Second", connection.fetch("name")
    assert_equal ["getMe"], @client.calls
    configure("enabled" => false, "token" => nil)
    plugin = @core.extensions.fetch("plugins").find { |row| row.fetch("id") == Rho::IngressTelegram::NAME }
    assert plugin.fetch("enabled")
    assert plugin.fetch("active")
    assert_nil saved_token
    response = @core.get(@core.require_daemon, "/telegram/connection?connection_public_id=#{@connection_id}")
    assert_equal "200", response.code
    assert_equal "disabled", @core.parse(response).fetch("connection").fetch("connection")
  end

  def test_clearing_the_saved_token_leaves_none_and_verifies_nothing
    configure("enabled" => true, "token" => TOKEN)
    configure("token" => nil)
    assert_equal({ "present" => false }, connection.fetch("token"))
    assert_nil saved_token
    assert_equal ["getMe"], @client.calls
  end

  def test_refused_token_and_invalid_settings_preserve_previous_configuration
    configure("enabled" => true, "token" => TOKEN, "name" => "First")
    before = connection
    saved = File.read(@home.settings_path)
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 401, description: "never expose #{TOKEN}")
    error = assert_raises(Rho::Core::Refused) { configure("token" => "replacement") }
    assert_equal 422, error.status
    refute_includes error.message, TOKEN
    assert_equal TOKEN, saved_token
    assert_equal saved, File.read(@home.settings_path)
    assert_equal before, connection
    error = assert_raises(Rho::Core::Refused) { configure("name" => "") }
    assert_equal 400, error.status
    assert_equal saved, File.read(@home.settings_path)
  end

  def test_bot_status_requires_an_explicit_bot_selector
    response = @core.get(@core.require_daemon, "/telegram")
    assert_equal "400", response.code
    refute_includes JSON.generate(@core.parse(response)), TOKEN
  end

  def test_credential_write_failure_keeps_the_previous_active_configuration
    configure("enabled" => true, "token" => TOKEN, "name" => "First")
    before, saved = connection, File.read(@home.settings_path)
    original = Rho::Home.instance_method(:write_settings)
    Rho::Home.remove_method(:write_settings)
    Rho::Home.define_method(:write_settings) { |_token| raise Rho::StateError, "credential write failed" }

    error = assert_raises(Rho::Core::Refused) { configure("token" => "replacement", "name" => "Second") }

    assert_equal 500, error.status
    assert_equal before, connection
    assert_equal saved, File.read(@home.settings_path)
    assert_equal TOKEN, saved_token
  ensure
    if original
      Rho::Home.remove_method(:write_settings)
      Rho::Home.define_method(:write_settings, original)
    end
  end

  def test_post_save_connection_application_failure_reports_saved_truthfully
    context = Struct.new(:home, :config).new(@home, Rho::Config.from_hash({ "mode" => "agent" }))
    context.define_singleton_method(:configure_plugin) do |id, operations:, enabled:, before_save:|
      before_save.call
      values = operations.to_h { |operation| [operation.fetch("path").last, operation.fetch("value")] }
      home.write_settings("plugins" => { id => { "enabled" => true, "configuration" => { "connections" => { "test" => values } } } })
      raise Rho::Settings::ApplyError, "Settings were saved, but applying them failed."
    end

    coordinator = Object.new
    coordinator.define_singleton_method(:bot_id) { |**| nil }
    coordinator.define_singleton_method(:admit_connection) { |**| nil }
    request = Protocol::HTTP::Request["POST", "/telegram/connection",
      { "content-type" => "application/json" }, [JSON.generate("token" => TOKEN, "enabled" => true)]]
    status, document = Rho::IngressTelegram.configure_connection(request, context, coordinator).to_a
    assert_equal 503, status
    assert_equal "settings_apply_failed", document.dig(:error, :code)
    assert_equal true, document.dig(:error, :saved)
    assert_includes File.read(@home.settings_path), TOKEN
    refute_includes JSON.generate(document), TOKEN
  end

  private

    def configure(changes)
      answer = @core.configure_telegram_connection(changes, connection_public_id: @connection_id)
      @connection_id = answer.fetch("connection").fetch("public_id")
      answer
    end

    def connection
      @core.telegram_connection(connection_public_id: @connection_id).fetch("connection")
    end

    def saved_token
      Rho::Config.read(@home.settings_path).dig("plugins", Rho::IngressTelegram::NAME, "configuration", "connections", @connection_id, "token")
    end
end
