require "test_helper"

class TelegramConnectionSettingsTest < Minitest::Test
  CONNECTION = "019a1111-2222-7333-8444-555555555555".freeze
  BOT = "019a1111-2222-7333-8444-555555555556".freeze
  OTHER = "019a1111-2222-7333-8444-555555555557".freeze

  def test_two_bots_share_one_connection_with_independent_targets_and_admission
    document = {
      "connections" => { CONNECTION => { "name" => "Shared", "token" => "synthetic-secret" } },
      "bots" => {
        BOT => { "enabled" => true, "connection_public_id" => CONNECTION, "target" => { "chat_id" => "7" }, "owner_id" => "7" },
        OTHER => { "enabled" => true, "connection_public_id" => CONNECTION, "target" => { "chat_id" => "-10", "topic_id" => 4 }, "owner_id" => "8" },
      },
    }
    connections = Rho::IngressTelegram::Settings.connections(document)
    bindings = Rho::IngressTelegram::Settings.bindings(document)
    assert_equal [CONNECTION], connections.keys
    assert_equal 2, bindings.length
    assert bindings.fetch(BOT).matches?(Rho::IngressTelegram::Update.new(telegram_update(chat: 7)))
    refute bindings.fetch(BOT).matches?(Rho::IngressTelegram::Update.new(telegram_update(chat: 8)))
    assert bindings.fetch(OTHER).matches?(Rho::IngressTelegram::Update.new(telegram_update(chat: -10, topic: 4)))
    refute bindings.fetch(OTHER).matches?(Rho::IngressTelegram::Update.new(telegram_update(chat: -10, topic: 5)))
    refute_includes JSON.generate(bindings.transform_values(&:to_h)), "synthetic-secret"
    refute_includes connections.fetch(CONNECTION).inspect, "synthetic-secret"
  end

  def test_duplicate_targets_are_refused_even_for_disabled_bots
    row = { "connection_public_id" => CONNECTION, "target" => { "chat_id" => "-10", "topic_id" => 4 } }
    error = assert_raises(Rho::ConfigurationError) do
      Rho::IngressTelegram::Settings.bindings("connections" => { CONNECTION => {} }, "bots" => { BOT => row, OTHER => row })
    end
    assert_includes error.message, "target"
  end

  def test_drafts_require_a_complete_binding_before_enablement
    draft = Rho::IngressTelegram::Settings.new({})
    refute draft.enabled?
    refute draft.configured?
    assert_raises(Rho::ConfigurationError) { Rho::IngressTelegram::Settings.new("enabled" => true) }
    assert_raises(Rho::ConfigurationError) do
      Rho::IngressTelegram::Settings.bindings("bots" => { BOT => { "connection_public_id" => CONNECTION } })
    end
    assert_raises(Rho::ConfigurationError) { Rho::IngressTelegram::Settings.bindings("bots" => { "rho" => {} }) }
  end

  def test_target_is_normalized_and_topics_require_a_group
    settings = Rho::IngressTelegram::Settings.new("target" => { "chat_id" => "-0010", "topic_id" => 4 })
    assert_equal({ "chat_id" => "-10", "topic_id" => 4 }, settings.target)
    [{ "chat_id" => "0" }, { "chat_id" => "7", "topic_id" => 4 }, { "chat_id" => "-10", "topic_id" => 0 }].each do |target|
      assert_raises(Rho::ConfigurationError) { Rho::IngressTelegram::Settings.new("target" => target) }
    end
  end

  def test_connections_do_not_accept_duplicate_tokens_or_bot_settings
    assert_raises(Rho::ConfigurationError) do
      Rho::IngressTelegram::Settings.connections("connections" => { CONNECTION => { "token" => "same" }, OTHER => { "token" => "same" } })
    end
    assert_raises(Rho::ConfigurationError) { Rho::IngressTelegram::ConnectionSettings.new("owner_id" => "7") }
    assert_raises(Rho::ConfigurationError) { Rho::IngressTelegram::Settings.new("token" => "synthetic-secret") }
  end

  private

    def telegram_update(chat:, topic: nil)
      { "update_id" => 1, "message" => { "from" => { "id" => 7 }, "chat" => { "id" => chat, "type" => chat.positive? ? "private" : "supergroup" },
        "message_thread_id" => topic, "is_topic_message" => !topic.nil? } }
    end
end
