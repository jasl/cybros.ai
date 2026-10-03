require "support/runtime"

class TelegramSpeechWorkflowTest < Minitest::Test
  include TelegramRuntimeSupport

  def setup
    super
    @settings = Rho::IngressTelegram::Settings.new({ "owner_id" => 1, "speech_model" => "speech/synthesize", "transcription_model" => "speech/transcribe" },
      env: { "RHO_TELEGRAM_BOT_TOKEN" => "fake-token" })
    @runtime = runtime
    @bridge.define_singleton_method(:speech_start) do |**fields|
      (@speech_requests ||= {})[fields.fetch(:idempotency_key)] ||= fields
      { "id" => "speech-#{@speech_requests.length}", "status" => "running" }
    end
    @bridge.define_singleton_method(:speech) do |id:, **|
      @speech_result || { "id" => id, "status" => "running" }
    end
    @bridge.define_singleton_method(:media_bytes) { |*, **| "audio bytes" }
    @bridge.define_singleton_method(:cancel_media) { |**fields| (@canceled ||= []) << fields }
    @bridge.define_singleton_method(:events) do |id, **fields|
      (@event_reads ||= []) << [id, fields]
      rows = @event_page ? @event_page.fetch("events") : []
      index = rows.index { |row| row.fetch("cursor") == fields[:after] }
      { "events" => index ? rows.drop(index + 1) : rows,
        "pagination" => { "next_after" => nil, "watermark" => rows.last&.fetch("sequence") || 0 } }
    end
    @client.define_singleton_method(:upload) { |method, params, **fields| call(method, params.merge(fields)) }
  end

  def test_text_is_delivered_while_synthesis_runs_and_restart_polls_the_same_one_shot
    open_with_mode("all")
    @bridge.turn_rows["conversation-1"] = [turn(0, "**Hello** from rho.")]
    @runtime.tick
    assert_includes @client.calls.select { |name, _| name == "sendMessage" }.map { |_, args| args[:text] }, "<b>Hello</b> from rho."
    assert_equal 1, speech_requests.length
    @runtime = runtime
    @bridge.instance_variable_set(:@speech_result, { "id" => "speech-1", "status" => "completed", "media" => audio })
    @runtime.tick
    assert_equal 1, speech_requests.length
    voice = @client.calls.find { |name, _| name == "sendVoice" }.last
    assert_equal "audio bytes", voice.fetch(:bytes)
    assert_equal 2, voice.fetch(:reply_parameters).fetch(:message_id)
    assert_equal "telegram:42:2:input", @state.read.fetch("messages").fetch("1:0:#{@client.last_message_id}")
  end

  def test_voice_only_uses_materialized_input_identity_not_the_last_chat_message
    open_with_mode("voice_only")
    @state.change do |document|
      tracker = document.fetch("routes").fetch("1:0").fetch("conversations").fetch("conversation-1")
      tracker.merge!("voice_inputs" => ["input-voice"], "request_cursor" => "before-voice")
    end
    @bridge.instance_variable_set(:@event_page, { "events" => [
      { "type" => "input_materialized", "cursor" => "voice-event", "sequence" => 1, "payload" => { "input_public_id" => "input-voice", "turn_public_id" => "turn-0" } },
      { "type" => "input_materialized", "cursor" => "text-event", "sequence" => 2, "payload" => { "input_public_id" => "input-text", "turn_public_id" => "turn-1" } },
    ], "pagination" => { "next_after" => "text-event" } })
    @bridge.turn_rows["conversation-1"] = [turn(0, "Voice answer."), turn(1, "Later text answer.")]
    @runtime.tick
    assert_equal ["Voice answer."], speech_requests.values.map { |row| row.fetch(:text) }
    assert_equal "before-voice", @bridge.instance_variable_get(:@event_reads).first.last.fetch(:after)
    @now += 5
    @runtime.tick
    assert_equal ["before-voice", "text-event"], @bridge.instance_variable_get(:@event_reads).map { |read| read.last.fetch(:after) },
      "voice mapping shares the request event cursor and never issues a second read in one refresh"
  end

  def test_parent_report_voice_keeps_the_report_identity_and_original_destination
    open_with_mode("all")
    report_id = "019a1234-5678-7000-8000-000000000001"
    sources = [{ "input_public_id" => "callback-a", "origin" => "child", "sender_agent_loop_public_id" => "loop-1",
      "result" => { "input_public_id" => "worker-a-input", "conversation_public_id" => "child-a",
        "turn_public_id" => "worker-a-turn", "variant_public_id" => "worker-a-variant", "requester_actor_public_id" => "speaker-1" } }]
    @bridge.define_singleton_method(:worker_result) { |*, **| nil }
    @bridge.instance_variable_set(:@event_page, { "events" => [
      { "type" => "input_materialized", "cursor" => "report-input", "sequence" => 1, "payload" => { "input_public_id" => report_id, "turn_public_id" => "turn-1" } },
      { "type" => "turn_status", "cursor" => "report-loop", "sequence" => 2, "payload" => { "turn_public_id" => "turn-1", "agent_loop_public_id" => "summary-loop" } },
    ] })
    @state.change do |document|
      document.fetch("requests").fetch("telegram:42:2:input")["result_destination"] = { "chat_id" => "-10", "topic_id" => 4, "group" => true }
    end
    @bridge.turn_rows["conversation-1"] = [turn(1, "Parent report.").merge("input_public_id" => report_id,
      "callback_sources" => sources, "loop_public_id" => "summary-loop")]
    @runtime.tick
    receipt = @state.read.fetch("deliveries").values.find { |row| row["voice"] }
    assert_equal sources, receipt.fetch("callback_sources")
    @bridge.instance_variable_set(:@speech_result, { "id" => "speech-1", "status" => "completed", "media" => audio })
    @now += 5
    @runtime.tick
    voice = @client.calls.find { |name, _| name == "sendVoice" }.last
    assert_equal "1", voice.fetch(:chat_id)
    voice_id = @client.last_message_id
    assert_equal "report:#{report_id}", @state.read.fetch("messages").fetch("1:0:#{voice_id}")
    @runtime.consume(telegram_message(3, "/new"))
    @runtime.consume(telegram_message(4, "/stop", reply_to: voice_id))
    assert_equal [["summary-loop", "agent_loop", "workspace-home"]], @bridge.stop_calls
    @runtime.consume(telegram_message(5, "Explain the spoken report", reply_to: voice_id))
    assert_equal "conversation-1", @bridge.inputs.fetch("telegram:42:5:input").fetch(:conversation_id)
  end

  def test_long_spoken_text_is_split_without_loss_and_stop_cancels_prepared_speech
    open_with_mode("all")
    text = "中文🌱 " * 500
    @bridge.turn_rows["conversation-1"] = [turn(0, text)]
    @runtime.tick
    pieces = @state.read.fetch("deliveries").values.filter_map { |row| row["speech_text"] }
    assert_equal Rho::IngressTelegram::Render.chunks(text).map(&:text).join, pieces.join
    assert pieces.all? { |piece| piece.bytesize <= 2_000 }
    assert_operator pieces.length, :>, 1
    @runtime.consume(telegram_message(3, "/stop"))
    refute @state.read.fetch("deliveries").values.any? { |row| row["voice"] }
    assert_equal 1, @bridge.instance_variable_get(:@canceled).length
  end

  def test_changed_variant_prevents_prepared_speech_from_being_sent
    open_with_mode("all")
    @bridge.turn_rows["conversation-1"] = [turn(0, "Old answer.")]
    @runtime.tick
    @bridge.turn_rows["conversation-1"] = [turn(0, "Replacement answer.").merge("variant_public_id" => "replacement")]
    @bridge.instance_variable_set(:@speech_result, { "id" => "speech-1", "status" => "completed", "media" => audio })
    @now += 5
    @runtime.tick
    refute @client.calls.any? { |method, _| method == "sendVoice" }
    refute @state.read.fetch("deliveries").values.any? { |row| row["voice"] }
    assert_equal [{ id: "speech-1", workspace_public_id: "workspace-home" }], @bridge.instance_variable_get(:@canceled)
  end

  def test_later_speech_parts_wait_for_the_previous_part_to_be_sent
    open_with_mode("all")
    @bridge.turn_rows["conversation-1"] = [turn(0, "中文 " * 500)]
    @runtime.tick
    @now += 5
    @runtime.tick
    assert_equal 1, speech_requests.length
    @bridge.instance_variable_set(:@speech_result, { "id" => "speech-1", "status" => "completed", "media" => audio })
    @now += 5
    @runtime.tick
    assert_equal 1, @client.calls.count { |name, _| name == "sendVoice" }
    @now += 5
    @runtime.tick
    assert_equal 2, speech_requests.length
  end

  def test_unspoken_voice_turn_mappings_are_removed_when_mode_is_off_or_text_empty
    open_with_mode("off")
    @state.change do |document|
      document.fetch("routes").fetch("1:0").fetch("conversations").fetch("conversation-1")["voice_turns"] = ["turn-0", "turn-1"]
    end
    @bridge.turn_rows["conversation-1"] = [turn(0, "No speech requested."), turn(1, "")]
    @runtime.tick
    assert_empty @state.read.fetch("routes").fetch("1:0").fetch("conversations").fetch("conversation-1").fetch("voice_turns")
    assert_empty speech_requests
  end

  def test_completed_speech_without_media_reports_failure_and_preserves_text
    open_with_mode("all")
    @bridge.turn_rows["conversation-1"] = [turn(0, "The written answer.")]
    @runtime.tick
    @bridge.instance_variable_set(:@speech_result, { "id" => "speech-1", "status" => "completed" })
    @now += 5
    @runtime.tick
    refute @client.calls.any? { |method, _| method == "sendVoice" }
    messages = @client.calls.filter_map { |method, params| params[:text] if method == "sendMessage" }
    assert_includes messages, "The written answer."
    assert messages.any? { |text| text.include?("spoken reply could not be generated") }
  end

  private

    def open_with_mode(mode)
      @runtime.consume(telegram_message(1, "/voice #{mode}"))
      @runtime.consume(telegram_message(2, "Hello"))
      @state.change { |document| document.fetch("deliveries").clear }
    end

    def speech_requests = @bridge.instance_variable_get(:@speech_requests) || {}

    def audio
      { "one_shot_public_id" => "speech-1", "index" => 0, "filename" => "speech.mp3", "content_type" => "audio/mpeg", "byte_size" => 11 }
    end
end
