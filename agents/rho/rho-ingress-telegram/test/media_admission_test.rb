require "support/runtime"

class TelegramMediaAdmissionTest < Minitest::Test
  include TelegramRuntimeSupport

  def setup
    super
    @settings = Rho::IngressTelegram::Settings.new({ "owner_id" => 1, "transcription_model" => "speech/transcribe" },
      env: { "RHO_TELEGRAM_BOT_TOKEN" => "fake-token" })
    @runtime = runtime
    @uploads, @transcriptions, @canceled = {}, {}, []
    @bridge.define_singleton_method(:stage_media) do |**fields|
      (@media_uploads ||= {})[fields.fetch(:idempotency_key)] ||= "upload-1"
    end
    @bridge.define_singleton_method(:transcribe) do |**fields|
      (@transcriptions ||= {})[fields.fetch(:idempotency_key)] ||= { "id" => "stt-1", "status" => "running" }
    end
    @bridge.define_singleton_method(:transcription) { |**| @transcription_result || { "id" => "stt-1", "status" => "running" } }
    @bridge.define_singleton_method(:cancel_media) { |**fields| (@canceled ||= []) << fields }
    @bridge.define_singleton_method(:conversation) { |*_args, **| @conversation || { "archived_at" => nil } }
    @client.define_singleton_method(:download) { |*_, **| "media bytes" }
  end

  def test_photo_is_uploaded_once_and_lost_input_reply_reuses_the_staged_identity
    receive(photo(1))
    @bridge.fail_input = true
    @runtime.tick
    assert_equal 1, @bridge.inputs.length
    assert_equal ["upload-1"], @bridge.inputs.values.first.fetch(:upload_public_ids)
    @runtime = runtime
    @runtime.tick
    assert_equal 1, @bridge.inputs.length
    assert_empty @state.read.fetch("pending_inputs")
    assert_equal 1, @bridge.instance_variable_get(:@media_uploads).length
  end

  def test_document_upload_identity_survives_restart_and_input_retry
    update = telegram_message(1, "Review this file")
    update.fetch("message")["document"] = { "file_id" => "doc", "file_name" => "report.pdf", "file_size" => 12,
      "mime_type" => "application/pdf" }
    receive(update)
    @bridge.fail_input = true
    @runtime.tick
    assert_equal ["upload-1"], @bridge.inputs.values.first.fetch(:upload_public_ids)
    @runtime = runtime
    @runtime.tick
    assert_equal 1, @bridge.inputs.length
    assert_equal 1, @bridge.instance_variable_get(:@media_uploads).length
    assert_empty @state.read.fetch("pending_inputs")
  end

  def test_waiting_voice_preserves_order_but_controls_and_other_chats_continue
    receive(voice(1))
    @runtime.tick
    receive(telegram_message(2, "later text"))
    receive(telegram_message(3, "/status"))
    receive(telegram_message(4, "other chat", user: 2))
    assert_equal ["other chat"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert @state.read.fetch("deliveries").key?("control:3")
    assert_equal 5, @state.read.fetch("offset")
    @bridge.instance_variable_set(:@transcription_result, { "id" => "stt-1", "status" => "completed", "text" => "transcribed request" })
    @runtime = runtime
    @runtime.tick
    @now += 5
    @runtime.tick
    assert_equal ["other chat", "transcribed request", "later text"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert_empty @state.read.fetch("pending_inputs")
  end

  def test_new_cancels_unadmitted_voice_in_the_old_scope
    receive(voice(1))
    @runtime.tick
    receive(telegram_message(2, "/new"))
    @bridge.instance_variable_set(:@transcription_result, { "id" => "stt-1", "status" => "completed", "text" => "must not submit" })
    @now += 5
    @runtime.tick
    assert_empty @bridge.inputs
    assert_empty @state.read.fetch("pending_inputs")
    assert_equal [{ id: "stt-1", workspace_public_id: "workspace-home" }], @bridge.instance_variable_get(:@canceled)
    assert_equal "conversation-2", @state.read.fetch("routes").fetch("1:0").fetch("current")
  end

  def test_reply_stop_cancels_only_the_selected_unadmitted_voice_after_restart
    receive(voice(1))
    @runtime.tick
    receive(voice(2))
    @runtime = runtime
    receive(telegram_message(3, "/stop", reply_to: 1, reply_user: 1))

    document = @state.read
    assert_equal ["2"], document.fetch("pending_inputs").keys
    assert document.fetch("requests").fetch("telegram:42:1:input").fetch("retired")
    assert_equal [{ id: "stt-1", workspace_public_id: "workspace-home" }], @bridge.instance_variable_get(:@canceled)
    assert_nil document["pending_update"]
    assert_equal 4, document.fetch("offset")
    assert_empty @bridge.stops

    receive(telegram_message(4, "later text"))
    @bridge.define_singleton_method(:transcribe) do |**|
      { "id" => "stt-2", "status" => "completed", "text" => "later voice" }
    end
    @bridge.instance_variable_set(:@transcription_result,
      { "id" => "stt-1", "status" => "completed", "text" => "canceled voice must not submit" })
    @runtime.tick
    @now += 5
    @runtime.tick

    assert_equal ["later voice", "later text"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert_empty @state.read.fetch("pending_inputs")
    assert_nil @state.read.fetch("requests").fetch("telegram:42:1:input")["input_id"]
  end

  def test_unadmitted_voice_rejects_other_requesters_and_steer_but_allows_owner_stop
    @state.change { |document| document.fetch("access").fetch("allowed_users") << "3" }
    receive(voice(1, user: 2, chat: -10, topic: 4))
    @runtime.tick
    receive(telegram_message(2, "/stop", user: 3, chat: -10, topic: 4, reply_to: 1, reply_user: 2))
    receive(telegram_message(3, "/steer change it", user: 2, chat: -10, topic: 4, reply_to: 1, reply_user: 2))

    assert_includes @state.read.fetch("deliveries").fetch("control:2").fetch("text"), "Only this task's requester or the bot owner"
    assert_includes @state.read.fetch("deliveries").fetch("control:3").fetch("text"), "No known execution"
    assert_equal ["1"], @state.read.fetch("pending_inputs").keys
    assert_nil @bridge.instance_variable_get(:@canceled)
    receive(telegram_message(4, "/stop", chat: -10, topic: 4, reply_to: 1, reply_user: 2))

    assert_empty @state.read.fetch("pending_inputs")
    assert_equal [{ id: "stt-1", workspace_public_id: "workspace-home" }], @bridge.instance_variable_get(:@canceled)
    assert_empty @bridge.inputs
    assert_empty @bridge.stops
  end

  def test_archive_discards_pending_voice_without_submitting_after_restore
    receive(voice(1))
    @runtime.tick
    @bridge.instance_variable_set(:@conversation, { "archived_at" => "2026-09-30T00:00:00Z" })
    @now += 5
    @runtime.tick
    @bridge.instance_variable_set(:@conversation, { "archived_at" => nil })
    @now += 5
    @runtime.tick
    assert_empty @bridge.inputs
    assert_empty @state.read.fetch("pending_inputs")
    assert_includes @client.calls.filter_map { |_, params| params[:text] }.join, "archived"
  end

  def test_ignoring_one_group_user_discards_only_their_unadmitted_media
    @state.change { |document| document.fetch("access").fetch("allowed_users") << "3" }
    @bridge.define_singleton_method(:transcribe) do |**fields|
      @transcriptions ||= {}
      @transcriptions[fields.fetch(:idempotency_key)] ||= { "id" => "stt-#{@transcriptions.length + 1}", "status" => "running" }
    end
    receive(telegram_message(1, "@rho_bot accepted A task", user: 2, chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    receive(voice(2, user: 2, chat: -10, topic: 4))
    receive(voice(3, user: 3, chat: -10, topic: 4))
    @runtime.tick
    receive(telegram_message(4, "/ignore add 2"))
    @now += 5
    @runtime.tick

    pending = @state.read.fetch("pending_inputs").values
    assert_equal ["3"], pending.map { |row| row.fetch("user_id") }
    assert_equal [{ id: "stt-1", workspace_public_id: "workspace-home" }], @bridge.instance_variable_get(:@canceled)
    assert_equal ["@rho_bot accepted A task"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert_empty @bridge.stops
    @bridge.instance_variable_set(:@transcription_result, { "id" => "stt-2", "status" => "completed", "text" => "B's voice task" })
    @runtime = runtime
    @runtime.tick

    assert_empty @state.read.fetch("pending_inputs")
    assert_equal "speaker-3", @bridge.inputs.values.last.fetch(:speaker)
    assert_includes @bridge.inputs.values.last.fetch(:text), "B's voice task"
    assert_equal 2, @bridge.inputs.length
  end

  private

    def voice(id, **options)
      telegram_message(id, "", **options).tap do |row|
        row.fetch("message").delete("text")
        row.fetch("message")["voice"] = { "file_id" => "voice", "file_size" => 12, "mime_type" => "audio/ogg" }
        if options[:chat]&.negative?
          row.fetch("message").merge!("caption" => "@rho_bot voice task",
            "caption_entities" => [{ "type" => "mention", "offset" => 0, "length" => 8 }])
        end
      end
    end

    def photo(id)
      telegram_message(id, "").tap do |row|
        row.fetch("message").delete("text")
        row.fetch("message")["caption"] = "Describe this"
        row.fetch("message")["photo"] = [{ "file_id" => "photo", "file_size" => 12 }]
      end
    end
end
