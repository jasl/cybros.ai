require "support/runtime"

class TelegramVoiceCommandsTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_voice_defaults_off_and_requires_a_configured_speech_model
    receive(telegram_message(1, "/voice"))
    assert_includes response(1), "off"
    receive(telegram_message(2, "/voice all"))
    assert_includes response(2), "speech_model"
    refute @state.read.fetch("routes").dig("1:0", "voice")
  end

  def test_voice_mode_is_persisted_per_topic_and_only_the_owner_change_groups
    @settings = Rho::IngressTelegram::Settings.new({ "speech_model" => "speech/model",
      "owner_id" => 1 },
      env: { "RHO_TELEGRAM_BOT_TOKEN" => "fake-token" })
    @runtime = runtime
    receive(telegram_message(1, "/voice voice_only", chat: -10, topic: 4))
    receive(telegram_message(2, "/voice all", chat: -10, topic: 5, user: 2))
    @runtime = runtime
    receive(telegram_message(3, "/voice", chat: -10, topic: 4))
    assert_includes response(3), "voice_only"
    assert_equal "voice_only", @state.read.fetch("routes").dig("-10:4:1", "voice")
    refute @state.read.fetch("routes").dig("-10:5:1", "voice")
    receive(telegram_message(4, "/voice off", chat: -10, topic: 4))
    assert_equal "off", @state.read.fetch("routes").dig("-10:4:1", "voice")
    assert_empty @bridge.opened
  end

  private

    def response(id) = @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")
end
