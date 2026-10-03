require "support/participation"

class TelegramParticipationReplyTest < Minitest::Test
  include TelegramParticipationSupport

  def test_immediate_reply_includes_the_sent_bot_message_before_history_is_recorded
    message_id = send_active_reply("Use the project shortcut to open the current workspace.")
    assert_empty @bridge.participation_records

    reply_to_active_message(4, message_id, "Use the project shortcut to open the current workspace.")

    assert_quoted_request("Use the project shortcut to open the current workspace.")
    assert_empty @bridge.participation_records, "receiving a reply does not wait for or invent history recording"
  end

  def test_known_reply_keeps_its_quoted_context_after_recording_restart_and_observe_off
    text = "The shortcut opens the currently selected project."
    message_id = send_active_reply(text)
    advance
    assert_equal 1, @bridge.participation_records.length

    group_message(4, "/observe off")
    @runtime = runtime
    reply_to_active_message(5, message_id, text)

    assert_quoted_request(text)
    refute group_room.fetch("observe")
    assert_equal 1, @bridge.participation_records.length
  end

  private

    def send_active_reply(text)
      enable_participation
      group_message(3, "Does anyone know a useful project shortcut?", user: 2)
      advance
      finish_participation(text)
      advance
      assert_includes sent_texts, text
      @client.last_message_id
    end

    def reply_to_active_message(update_id, message_id, text)
      raw = telegram_message(update_id, "Please explain that", user: 2, chat: -10, topic: 4,
        date: @now.to_i, reply_to: message_id)
      raw.fetch("message").fetch("reply_to_message")["text"] = text
      @runtime.consume(raw)
    end

    def assert_quoted_request(text)
      request = @bridge.inputs.values.last
      assert_equal "Please explain that", request.fetch(:text)
      context = request.fetch(:inline, []).map { |entry| entry.fetch("text") }.join("\n")
      assert_includes context, text
      assert_match(/quot(?:e|ed|ing)|replying to/i, context)
      assert_equal "speaker-2", request.fetch(:speaker)
      assert_equal %w[read ls find grep task compose wait ask], request.fetch(:tool_names)
      assert_equal "2", @state.read.fetch("requests").values.last.fetch("owner_id")
      assert_equal ["-10:4:2"], @state.read.fetch("routes").keys
    end
end
