require "test_helper"

class TelegramConfigurationTest < Minitest::Test
  CONNECTION = "019a1111-2222-7333-8444-555555555551".freeze
  BOT = "019a1111-2222-7333-8444-555555555552".freeze
  OTHER = "019a1111-2222-7333-8444-555555555553".freeze

  def setup
    @config = Rho::Config.from_hash({ "mode" => "agent", "plugins" => { Rho::IngressTelegram::NAME => {
      "enabled" => true, "configuration" => {
        "connections" => { CONNECTION => { "name" => "Shared", "token" => "connection-secret" } },
        "bots" => { BOT => { "enabled" => true, "connection_public_id" => CONNECTION,
          "target" => { "chat_id" => "7" }, "owner_id" => "7" } },
      },
    } } })
    @configuration = Rho::IngressTelegram::Configuration.new(config: @config, clients: ->(*) { raise "Bot settings must not perform Telegram IO" })
  end

  def test_preparation_normalizes_only_the_supplied_bot_fields_without_mutating_saved_configuration
    before = @config.to_h
    change = @configuration.prepare({ "owner_id" => "008", "target" => { "chat_id" => "-0010", "topic_id" => "4" } }, agent_public_id: BOT)
    assert_equal [{ "op" => "set", "path" => ["bots", BOT, "owner_id"], "value" => "8" },
      { "op" => "set", "path" => ["bots", BOT, "target"], "value" => { "chat_id" => "-10", "topic_id" => 4 } }], change.operations
    assert_equal BOT, change.agent_public_id
    assert_equal CONNECTION, change.connection_public_id
    assert change.enabled
    assert_nil change.token
    assert_nil change.bot
    assert_equal before, @config.to_h
  end

  def test_disabled_drafts_can_clear_the_target_but_enabled_bots_must_be_complete
    change = @configuration.prepare({ "enabled" => false, "target" => nil }, agent_public_id: BOT)
    assert_nil change.operations.last.fetch("value")
    refute change.enabled
    assert_raises(Rho::ConfigurationError) { @configuration.prepare({ "target" => nil }, agent_public_id: BOT) }
    assert_raises(Rho::ConfigurationError) { @configuration.prepare({ "enabled" => true }, agent_public_id: OTHER) }
  end

  def test_token_and_mutable_access_lists_are_not_bot_configuration
    [{ "token" => "" }, { "enabled" => "true" }, { "owner_id" => 0 },
      { "stale_after" => 1.5 }, { "allowed_users" => ["8"] }, { "unexpected" => true }].each do |input|
      assert_raises(Rho::ConfigurationError) { @configuration.prepare(input, agent_public_id: BOT) }
    end
    assert_equal "connection-secret", @config.plugin_configuration(Rho::IngressTelegram::NAME).dig("connections", CONNECTION, "token")
  end

  def test_an_explicit_agent_uuid_and_known_connection_are_required
    [nil, "rho", "helper"].each do |id|
      assert_raises(Rho::ConfigurationError) { @configuration.prepare({}, agent_public_id: id) }
    end
    assert_raises(Rho::ConfigurationError) { @configuration.prepare({ "connection_public_id" => OTHER }, agent_public_id: BOT) }
  end

  def test_duplicate_targets_are_rejected_even_when_one_bot_is_disabled
    error = assert_raises(Rho::ConfigurationError) do
      @configuration.prepare({ "enabled" => false, "connection_public_id" => CONNECTION, "target" => { "chat_id" => "7" } }, agent_public_id: OTHER)
    end
    assert_includes error.message, "already bound"
    assert_raises(Rho::ConfigurationError) { @configuration.prepare({ "target" => { "chat_id" => "7", "topic_id" => 1 } }, agent_public_id: BOT) }
  end
end
