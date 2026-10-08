require "support/runtime"

class TelegramUnsupportedSideCommandsTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_side_and_btw_never_open_a_conversation_or_admit_input_for_any_requester
    sources = [{}, { user: 2 }, { chat: -10, topic: 7 }, { user: 2, chat: -10, topic: 7 }]
    sources.each_with_index do |source, index|
      %w[side btw].each_with_index do |command, offset|
        id = index * 2 + offset + 1
        receive(telegram_message(id, "/#{command}@rho_bot Explain this", **source))
        assert_includes @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text"), "not available in Telegram"
      end
    end

    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_empty @bridge.speakers
    assert_empty @bridge.stops
    assert_empty @bridge.memory_anchors
    assert_empty @state.read.fetch("routes")
    assert_empty @state.read.fetch("requests")
  end

  def test_disabled_commands_and_replays_keep_current_work_and_delivery_unchanged
    receive(telegram_message(1, "Keep working"))
    routes, requests, inputs = @state.read.values_at("routes", "requests") + [@bridge.inputs.dup]
    %w[side btw].each_with_index do |command, index|
      update = telegram_message(index + 2, "/#{command} Explain the current work", reply_to: 1, reply_user: 1)
      receive(update)
      @runtime = runtime
      receive(update)
    end

    assert_equal routes, @state.read.fetch("routes")
    assert_equal requests, @state.read.fetch("requests")
    assert_equal inputs, @bridge.inputs
    assert_equal 1, @bridge.opened.length
    assert_empty @bridge.stops

    @bridge.turn_rows["conversation-1"] = [turn(0, "Original answer")]
    4.times do
      @runtime.tick
      @now += Rho::IngressTelegram::Runtime::RECONCILE_INTERVAL
    end
    sent = @client.calls.select { |method, params| method == "sendMessage" && params[:text] == "Original answer" }
    assert_equal 1, sent.length
  end

  def test_disabled_commands_in_media_captions_never_prepare_or_admit_media
    %w[side btw].each_with_index do |command, index|
      update = telegram_message(index + 1, "")
      update.fetch("message").delete("text")
      update.fetch("message").merge!("caption" => "/#{command} Explain this image",
        "photo" => [{ "file_id" => "photo", "width" => 100, "height" => 100, "file_size" => 20 }])
      receive(update)
      assert_includes @state.read.fetch("deliveries").fetch("control:#{index + 1}").fetch("text"), "not available in Telegram"
    end

    assert_empty @state.read.fetch("pending_inputs")
    assert_empty @bridge.inputs
    assert_empty @bridge.opened
    assert_empty @bridge.speakers
  end
end
