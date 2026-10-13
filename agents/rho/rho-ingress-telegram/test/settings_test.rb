require "test_helper"

class TelegramSettingsTest < Minitest::Test
  def test_owner_is_explicit_and_normalized_once
    settings = Rho::IngressTelegram::Settings.new({ "owner_id" => "0007" })
    assert_equal "7", settings.owner_id
    assert settings.owner?(7)
    assert settings.owner?("7")
    refute settings.owner?(8)
    refute settings.owner?(nil)
  end

  def test_a_configured_target_does_not_infer_an_owner
    settings = Rho::IngressTelegram::Settings.new({ "enabled" => true,
      "connection_public_id" => "019a1111-2222-7333-8444-555555555551", "target" => { "chat_id" => "7" } })
    assert settings.enabled?
    assert_nil settings.owner_id
    refute settings.owner?(nil)
    refute settings.owner?("")
    refute settings.owner?(7)
  end

  def test_message_grouping_defaults_to_two_seconds_and_accepts_zero_through_ten
    assert_equal 2, Rho::IngressTelegram::Settings.new({}).input_debounce_seconds
    (0..10).each do |seconds|
      settings = Rho::IngressTelegram::Settings.new({ "input_debounce_seconds" => seconds.to_s })
      assert_equal seconds, settings.input_debounce_seconds
      assert_equal seconds, settings.to_h.fetch("input_debounce_seconds")
    end
    [nil, 11, -1, 1.5, "soon"].each do |value|
      assert_raises(Rho::ConfigurationError) { Rho::IngressTelegram::Settings.new({ "input_debounce_seconds" => value }) }
    end
  end

  def test_owner_must_be_a_positive_integer_when_configured
    [0, -7, "alice", 7.2, false, ""].each do |id|
      assert_raises(Rho::ConfigurationError) do
        Rho::IngressTelegram::Settings.new({ "owner_id" => id })
      end
    end
    assert_nil Rho::IngressTelegram::Settings.new({ "owner_id" => nil }).owner_id
  end

  def test_mutable_access_configuration_is_rejected
    %w[allowed_users managers allowed_chats].each do |key|
      error = assert_raises(Rho::ConfigurationError) do
        Rho::IngressTelegram::Settings.new({ key => [] })
      end
      assert_includes error.message, "unknown setting #{key}"
    end
  end

  def test_media_and_stale_settings_are_preserved
    settings = Rho::IngressTelegram::Settings.new({ "owner_id" => 7, "stale_after" => 30,
      "transcription_model" => " provider/transcribe ", "speech_model" => " provider/speech " })
    assert_equal 30, settings.stale_after
    assert_equal "provider/transcribe", settings.transcription_model
    assert_equal "provider/speech", settings.speech_model
    assert_raises(Rho::ConfigurationError) { Rho::IngressTelegram::Settings.new({ "stale_after" => 0 }) }
  end
end
