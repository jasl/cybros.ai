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
    @config = Rho::Config.from_hash("mode" => "agent", "extensions" => ["rho/web-tools"])
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_preparation_verifies_without_persisting_or_polling
    change = prepare("enabled" => true, "token" => " secret ", "owner_id" => "007")
    assert_equal ["getMe"], @client.calls
    assert @client.closed
    assert_equal ["secret"], @tokens
    assert_equal ["rho/web-tools", "rho/ingress-telegram"], change.patch.fetch("extensions")
    assert_equal "7", change.patch.dig("telegram", "owner_id")
    assert_equal({ "id" => 42, "username" => "configuration_bot" }, change.bot)
    assert_equal "", Rho::IngressTelegram::TokenFile.new(@home).read
    refute_includes JSON.generate(change.patch), "secret"
    change.persist_token(@home)
    settings = Rho::IngressTelegram::Settings.new(change.patch.fetch("telegram"), home: @home,
      env: { "RHO_TELEGRAM_BOT_TOKEN" => "environment" })
    assert_equal "secret", settings.token
    assert_equal "saved", settings.token_source
  end

  def test_clearing_saved_token_uses_environment_and_can_disable_without_a_token
    Rho::IngressTelegram::TokenFile.new(@home).write("saved")
    change = prepare({ "enabled" => true, "token" => nil }, env: { "RHO_TELEGRAM_BOT_TOKEN" => "environment" })
    assert_equal ["environment"], @tokens
    change.persist_token(@home)
    assert_equal "", Rho::IngressTelegram::TokenFile.new(@home).read
    Rho::IngressTelegram::TokenFile.new(@home).write("saved")
    change = prepare("enabled" => false, "token" => nil)
    assert_nil change.bot
    change.persist_token(@home)
    assert_equal "", Rho::IngressTelegram::TokenFile.new(@home).read
  end

  def test_omitted_token_is_preserved_and_plain_settings_need_no_telegram_io
    Rho::IngressTelegram::TokenFile.new(@home).write("saved")
    @config = Rho::Config.from_hash(@config.to_h.merge("extensions" => ["rho/ingress-telegram"]))
    change = prepare("owner_id" => nil, "stale_after" => 60, "speech_model" => "provider/speech")
    change.persist_token(@home)
    assert_equal "saved", Rho::IngressTelegram::TokenFile.new(@home).read
    assert_nil change.patch.dig("telegram", "owner_id")
    assert_equal 60, change.patch.dig("telegram", "stale_after")
    assert_empty @client.calls
  end

  def test_invalid_configuration_never_verifies_or_writes
    [{ "enabled" => true }, { "token" => "" }, { "enabled" => "true" }, { "owner_id" => 0 },
      { "stale_after" => 1.5 }, { "unexpected" => true }].each do |input|
      assert_raises(Rho::ConfigurationError) { prepare(input) }
    end
    assert_empty @client.calls
    refute_path_exists File.join(@directory, "telegram", "token.json")
  end

  def test_another_bot_and_failed_verification_leave_the_saved_token_intact
    Rho::IngressTelegram::TokenFile.new(@home).write("saved")
    assert_raises(Rho::ConfigurationError) { prepare({ "token" => "replacement" }, bot_id: "99") }
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 401, description: "unauthorized")
    assert_raises(Rho::IngressTelegram::Client::Refused) { prepare("token" => "replacement") }
    assert_equal "saved", Rho::IngressTelegram::TokenFile.new(@home).read
    assert @client.closed
  end

  private

    def prepare(input = {}, env: {}, bot_id: nil, **keywords)
      Rho::IngressTelegram::Configuration.new(home: @home, config: @config, env: env,
        clients: ->(token) { @tokens << token; @client }).prepare(input.merge(keywords), bot_id: bot_id)
    end
end
