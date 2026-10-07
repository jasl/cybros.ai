require "test_helper"

class TelegramConfigurationTest < Minitest::Test
  class Client
    attr_reader :calls, :closed
    attr_accessor :failure, :bot_id
    def initialize
      @calls, @bot_id = [], 42
    end
    def call(method)
      @calls << method
      raise failure if failure

      { "id" => bot_id, "username" => "configuration_bot", "first_name" => "Private name" }
    end
    def close = @closed = true
  end

  def setup
    @directory = Dir.mktmpdir("rho-telegram-configuration")
    @home = Rho::Home.resolve(root: @directory, base_url: "https://nexus.example").prepare
    @client, @tokens = Client.new, []
    configure
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_preparation_verifies_without_persisting_or_polling
    change = prepare("enabled" => true, "token" => " secret ", "owner_id" => "007")
    assert_equal ["getMe"], @client.calls
    assert @client.closed
    assert_equal ["secret"], @tokens
    assert change.enabled
    assert_equal "7", changed(change).fetch("owner_id")
    assert_equal({ "id" => 42, "username" => "configuration_bot" }, change.bot)
    assert_nil @config.plugin_configuration(Rho::IngressTelegram::NAME)["token"]
    refute_path_exists @home.settings_path
    settings = Rho::IngressTelegram::Settings.new(changed(change),
      env: { "RHO_TELEGRAM_BOT_TOKEN" => "environment" })
    assert_equal "secret", settings.token
    assert_equal "saved", settings.token_source
  end

  def test_clearing_saved_token_uses_environment_and_can_disable_without_a_token
    configure(token: "saved")
    change = prepare({ "enabled" => true, "token" => nil }, env: { "RHO_TELEGRAM_BOT_TOKEN" => "environment" })
    assert_equal ["environment"], @tokens
    assert_nil changed(change)["token"]
    configure(token: "saved")
    change = prepare("enabled" => false, "token" => nil)
    assert_nil change.bot
    assert_nil changed(change)["token"]
  end

  def test_omitted_token_is_preserved_and_plain_settings_need_no_telegram_io
    configure(token: "saved")
    configure(token: "saved", enabled: true)
    change = prepare("owner_id" => nil, "stale_after" => 60, "speech_model" => "provider/speech")
    assert_equal "saved", @config.plugin_configuration(Rho::IngressTelegram::NAME).fetch("token")
    assert_nil changed(change).fetch("owner_id")
    assert_equal 60, changed(change).fetch("stale_after")
    assert_empty @client.calls
  end

  def test_invalid_configuration_never_verifies_or_writes
    [{ "token" => "" }, { "enabled" => "true" }, { "owner_id" => 0 },
      { "stale_after" => 1.5 }, { "unexpected" => true }].each do |input|
      assert_raises(Rho::ConfigurationError) { prepare(input) }
    end
    assert_empty @client.calls
    refute_path_exists File.join(@directory, "telegram", "token.json")
  end

  def test_another_bot_and_failed_verification_leave_the_saved_token_intact
    configure(token: "saved")
    assert_raises(Rho::ConfigurationError) { prepare({ "token" => "replacement" }, bot_id: "99") }
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 401, description: "unauthorized")
    assert_raises(Rho::IngressTelegram::Client::Refused) { prepare("token" => "replacement") }
    assert_equal "saved", @config.plugin_configuration(Rho::IngressTelegram::NAME).fetch("token")
    assert @client.closed
  end

  def test_enablement_can_be_saved_before_a_token_is_configured
    change = prepare("enabled" => true)
    assert change.enabled
    assert_empty change.token
    assert_nil change.bot
    assert_empty @client.calls
  end

  private

    def configure(token: nil, enabled: false)
      @config = Rho::Config.from_hash({ "mode" => "agent", "plugins" => {
        Rho::IngressTelegram::NAME => { "enabled" => enabled, "configuration" => { "token" => token } },
      } })
    end

    def changed(change)
      change.operations.each_with_object(@config.plugin_configuration(Rho::IngressTelegram::NAME).dup) do |operation, value|
        value[operation.fetch("path").fetch(0)] = operation.fetch("value")
      end
    end

    def prepare(input = {}, env: {}, bot_id: nil, **keywords)
      Rho::IngressTelegram::Configuration.new(config: @config, env: env,
        clients: ->(token) { @tokens << token; @client }).prepare(input.merge(keywords), bot_id: bot_id)
    end
end
