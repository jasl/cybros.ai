require "test_helper"

class TelegramConnectionConfigurationTest < Minitest::Test
  CONNECTION = "019a1111-2222-7333-8444-555555555555".freeze
  BOT = "019a1111-2222-7333-8444-555555555556".freeze

  class Client
    attr_reader :calls, :closed
    attr_accessor :failure
    def initialize = @calls = []
    def call(method)
      @calls << method
      raise failure if failure

      { "id" => 42, "username" => "configuration_bot", "first_name" => "Not part of the projection" }
    end
    def close = @closed = true
  end

  def setup
    @client = Client.new
    @config = Rho::Config.from_hash({ "mode" => "agent", "plugins" => { Rho::IngressTelegram::NAME => {
      "enabled" => true, "configuration" => { "connections" => { CONNECTION => { "name" => "Shared", "token" => "saved" } },
        "bots" => { BOT => { "connection_public_id" => CONNECTION, "target" => { "chat_id" => "7" } } } },
    } } })
    @configuration = Rho::IngressTelegram::Configuration.new(config: @config, clients: ->(_token) { @client })
  end

  def test_new_connection_verifies_once_and_returns_only_safe_identity
    prepared = @configuration.prepare_connection({ "name" => "Second", "token" => " new-secret " })
    assert_match Rho::IngressTelegram::Settings::UUID, prepared.connection_public_id
    refute_equal CONNECTION, prepared.connection_public_id
    assert_equal ["getMe"], @client.calls
    assert @client.closed
    assert_equal({ "id" => 42, "username" => "configuration_bot" }, prepared.bot)
    assert_equal "new-secret", prepared.token
    assert_equal ["connections", prepared.connection_public_id], prepared.operations.first.fetch("path").first(2)
    assert_equal "saved", @config.plugin_configuration(Rho::IngressTelegram::NAME).dig("connections", CONNECTION, "token")
  end

  def test_omitted_token_is_preserved_and_clearing_does_not_verify
    prepared = @configuration.prepare_connection({ "name" => "Renamed" }, connection_public_id: CONNECTION)
    assert_equal "saved", prepared.token
    assert_equal [{ "op" => "set", "path" => ["connections", CONNECTION, "name"], "value" => "Renamed" }], prepared.operations
    assert_empty @client.calls
    cleared = @configuration.prepare_connection({ "token" => nil }, connection_public_id: CONNECTION)
    assert_nil cleared.operations.first.fetch("value")
    assert_empty cleared.token
    assert_empty @client.calls
  end

  def test_invalid_token_or_replacement_identity_cannot_change_saved_configuration
    assert_raises(Rho::ConfigurationError) { @configuration.prepare_connection({ "token" => "saved" }) }
    assert_raises(Rho::ConfigurationError) { @configuration.prepare_connection({ "token" => " " }, connection_public_id: CONNECTION) }
    assert_empty @client.calls
    assert_raises(Rho::ConfigurationError) do
      @configuration.prepare_connection({ "token" => "replacement" }, connection_public_id: CONNECTION, bot_id: "99")
    end
    assert @client.closed
    assert_equal "saved", @config.plugin_configuration(Rho::IngressTelegram::NAME).dig("connections", CONNECTION, "token")
  end

  def test_bot_admission_change_needs_no_telegram_io
    prepared = @configuration.prepare({ "owner_id" => "007", "enabled" => true }, agent_public_id: BOT)
    assert_equal [{ "op" => "set", "path" => ["bots", BOT, "owner_id"], "value" => "7" },
      { "op" => "set", "path" => ["bots", BOT, "enabled"], "value" => true }], prepared.operations
    assert_nil prepared.token
    assert_nil prepared.bot
    assert_empty @client.calls
  end

  def test_schema_redacts_only_connection_tokens_and_has_no_main_slot
    descriptor = Rho::Extensions::Catalog.new.fetch(Rho::IngressTelegram::NAME)
    view = descriptor.schema.view(descriptor.schema.normalize(@config.plugin_configuration(Rho::IngressTelegram::NAME))).to_h
    refute_includes JSON.generate(view), "saved"
    assert_equal [["connections", CONNECTION, "token"]], view.fetch(:secrets).map { |row| row.fetch(:path) }
    assert_empty Rho::IngressTelegram::Settings.bindings({})
  end
end
