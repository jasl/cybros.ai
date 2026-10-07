require "support/runtime"

class TelegramDestinationWorkflowTest < Minitest::Test
  include TelegramRuntimeSupport

  def setup
    super
    @bridge.define_singleton_method(:submit) do |id, **request|
      result = super(id, **request)
      number = result.fetch("input").fetch("public_id").delete_prefix("input-").to_i
      result.fetch("input")["public_id"] = TelegramDestinationWorkflowTest.task_id(number)
      result
    end
    @bridge.define_singleton_method(:recent_turns) do |id, before_position: nil, workspace_public_id:|
      raise @read_failure if @read_failure

      rows = @turn_rows.fetch(id, []).select { |row| before_position.nil? || row.fetch("position") < before_position }
      selected = rows.last(2)
      { "turns" => selected, "pagination" => { "has_older" => rows.length > selected.length,
        "before_position" => selected.first&.fetch("position") } }
    end
    @execution_reads = []
    reads = @execution_reads
    @bridge.define_singleton_method(:task_execution) do |id, workspace_public_id:|
      reads << [id, workspace_public_id]
      { "status" => "running" }
    end
    @runtime.consume(telegram_message(1, "Prepare a report"))
    @runtime.consume(telegram_message(2, "/new", chat: -10, topic: 4))
  end

  def self.task_id(number) = "019a1234-5678-7000-8000-#{format("%012d", number)}"

  def test_completed_result_is_copied_once_without_changing_source_or_replying_to_its_message
    @bridge.turn_rows["conversation-1"] = [turn(0, "Finished report")]
    source = @state.read.fetch("requests").fetch("telegram:42:1:input")
    @runtime.consume(telegram_message(3, "/deliver #{task_id(1)} -10:4"))
    assert_includes feedback(3), "Already queued messages keep their destinations"
    assert_equal source, @state.read.fetch("requests").fetch("telegram:42:1:input").except("result_destination")
    drain
    @runtime.consume(telegram_message(4, "/deliver #{task_id(1)} -10:4"))
    drain
    sends = result_sends("Finished report")
    assert_equal 1, sends.length
    assert_equal "-10", sends.first.fetch(:chat_id)
    assert_equal 4, sends.first.fetch(:message_thread_id)
    refute sends.first.key?(:reply_parameters)
    assert_includes sends.first.fetch(:text), task_id(1)
    assert_equal 1, @bridge.inputs.length
  end

  def test_owner_controls_original_task_from_only_its_exact_destination_after_restart
    @runtime.consume(telegram_message(3, "/deliver #{task_id(1)} -10:4"))
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @runtime = runtime(default_model: "vendor/changed")
    @runtime.consume(telegram_message(4, "/status #{task_id(1)}", chat: -10, topic: 4))
    @runtime.consume(telegram_message(5, "/steer #{task_id(1)} keep the report concise", chat: -10, topic: 4))
    @runtime.consume(telegram_message(6, "/stop #{task_id(1)}", chat: -10, topic: 4))
    assert_equal [["loop-1", "workspace-home"]], @execution_reads
    input = @bridge.inputs.fetch("telegram:42:5:input")
    assert_equal "conversation-1", input.fetch(:conversation_id)
    assert_equal "loop-1", input.fetch(:expected_steering_run_public_id)
    assert_equal [["loop-1", "run", "workspace-home"]], @bridge.stop_calls
    assert_nil @bridge.memory_bindings.fetch("conversation-1")
    @runtime.consume(telegram_message(7, "/stop #{task_id(1)}", chat: -10, topic: 5))
    @runtime.consume(telegram_message(8, "/stop #{task_id(1)}", user: 2, chat: -10, topic: 4))
    @runtime.consume(telegram_message(9, "/task pause #{task_id(1)}", chat: -10, topic: 4))
    assert_includes feedback(7), "not available in this chat/topic"
    assert_includes feedback(8), "not available in this chat/topic"
    assert_includes feedback(9), "not available in this chat/topic"
    assert_equal 1, @bridge.stops.length
  end

  def test_exported_result_reply_does_not_continue_the_source_conversation
    @bridge.turn_rows["conversation-1"] = [turn(0, "Finished report")]
    @runtime.consume(telegram_message(3, "/deliver #{task_id(1)} -10:4"))
    drain
    receipt = @state.read.fetch("deliveries").values.find { |entry| entry["result_copy"] }
    @runtime.consume(telegram_message(4, "Read my private notes next", chat: -10, topic: 4,
      reply_to: receipt.fetch("message_ids").first))
    assert_includes feedback(4), "/steer #{task_id(1)}"
    assert_equal 1, @bridge.inputs.length
    assert_nil @bridge.memory_bindings.fetch("conversation-1")
  end

  def test_destinations_and_changes_require_owner_and_only_offer_known_allowed_rooms
    @runtime.consume(telegram_message(3, "A member's private request", user: 2))
    @runtime.consume(telegram_message(4, "/destinations"))
    assert_includes feedback(4), "1:0"
    assert_includes feedback(4), "-10:4"
    refute_includes feedback(4), "2:0"
    @runtime.consume(telegram_message(5, "/destinations", user: 2))
    @runtime.consume(telegram_message(6, "/deliver #{task_id(2)} -10:4", user: 2))
    assert_includes feedback(5), "Only the bot owner"
    assert_includes feedback(6), "Only the bot owner"
    ["2:0", "-10:5", "-20:0", "@a_group"].each_with_index do |destination, index|
      @runtime.consume(telegram_message(7 + index, "/deliver #{task_id(1)} #{destination}"))
      assert_includes feedback(7 + index), "destination is not available"
    end
    @state.change { |document| document.fetch("access")["allowed_chats"] = [] }
    @runtime.consume(telegram_message(11, "/deliver #{task_id(1)} -10:4"))
    assert_includes feedback(11), "destination is not available"
    refute @state.read.fetch("requests").values.any? { |request| request["result_destination"] }
  end

  def test_invalid_task_reference_never_selects_the_current_request
    ["/deliver", "/deliver bad -10:4", "/deliver #{task_id(1)}", "/deliver #{task_id(1)} -10:4 extra",
      "/deliver #{task_id(99)} -10:4"].each_with_index do |command, index|
      @runtime.consume(telegram_message(3 + index, command))
      assert_match(/Use \/deliver|task ID is not available/, feedback(3 + index))
    end
    refute @state.read.fetch("requests").fetch("telegram:42:1:input").key?("result_destination")
  end

  def test_future_supplementary_result_keeps_task_destination_after_new_and_restart
    @runtime.consume(telegram_message(3, "/deliver #{task_id(1)} -10:4"))
    assert_includes feedback(3), "no completed result to copy"
    @runtime.consume(telegram_message(4, "/new"))
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @runtime = runtime
    @bridge.turn_rows["conversation-1"] = [turn(0, "First report"), turn(1, "Later result")]
    @bridge.event_rows["conversation-1"] = derived_events(1)
    drain
    assert_equal ["-10"], result_sends("First report").map { |row| row.fetch(:chat_id) }
    assert_equal ["-10"], result_sends("Later result").map { |row| row.fetch(:chat_id) }
    assert_equal "conversation-3", @state.read.fetch("routes").fetch("1:0").fetch("current")
    assert_equal "loop-1", @state.read.fetch("requests").fetch("telegram:42:1:input").fetch("run_id")
    assert_nil @bridge.memory_bindings.fetch("conversation-1")
  end

  def test_latest_completed_result_searches_older_pages_and_ignores_unrelated_requests
    @runtime.consume(telegram_message(3, "An unrelated request"))
    @bridge.turn_rows["conversation-1"] = [turn(0, "First report"), turn(1, "Unrelated answer"),
      turn(2, "Latest task report"), turn(3, "Other answer"), turn(4, "Still another answer")]
    @bridge.event_rows["conversation-1"] = derived_events(2)
    @runtime.consume(telegram_message(4, "/deliver #{task_id(1)} -10:4"))
    copy = @state.read.fetch("deliveries").values.find { |entry| entry["result_copy"] }
    assert_includes copy.fetch("text"), "Latest task report"
    refute_includes copy.fetch("text"), "First report"
    refute_includes copy.fetch("text"), "Other answer"
    assert_equal "turn-2", copy.fetch("turn_id")
  end

  def test_latest_completed_result_maps_new_history_beyond_an_older_saved_watermark
    @bridge.define_singleton_method(:events) do |id, after: nil, workspace_public_id:|
      all = @event_rows.fetch(id, [])
      rows = all.select { |row| !after || row.fetch("sequence") > after.to_i }.first(100)
      { "events" => rows, "pagination" => { "watermark" => all.last&.fetch("sequence") || 0,
        "next_after" => rows.last&.fetch("cursor") } }
    end
    @bridge.turn_rows["conversation-1"] = [turn(0, "Original report"), turn(1, "Earlier supplement")]
    @bridge.event_rows["conversation-1"] = unrelated_events(1..100) + derived_events(1, input: "earlier", sequence: 101)
    @runtime.tick
    tracker = @state.read.fetch("routes").fetch("1:0").fetch("conversations").fetch("conversation-1")
    assert_equal 103, tracker.fetch("request_head")
    assert_equal "100", tracker.fetch("request_cursor")
    @bridge.turn_rows.fetch("conversation-1") << turn(2, "Newest supplement")
    @bridge.event_rows.fetch("conversation-1").concat(unrelated_events(104..200) + derived_events(2, input: "newest", sequence: 201))

    @runtime.consume(telegram_message(3, "/deliver #{task_id(1)} -10:4"))

    copy = @state.read.fetch("deliveries").values.find { |entry| entry["result_copy"] }
    assert_equal "turn-2", copy.fetch("turn_id")
    assert_includes copy.fetch("text"), "Newest supplement"
    assert_equal 1, @state.read.fetch("deliveries").values.count { |entry| entry["result_copy"] }
  end

  def test_destination_steer_refuses_a_retired_source_and_consumes_the_update
    @runtime.consume(telegram_message(3, "/deliver #{task_id(1)} -10:4"))
    @bridge.read_failure = Rho::Core::Refused.new("no longer readable", status: 404, code: "not_found")
    @runtime.tick
    refute @state.read.fetch("routes").fetch("1:0").fetch("conversations").key?("conversation-1")

    @runtime.consume(telegram_message(4, "/steer #{task_id(1)} Keep working", chat: -10, topic: 4))

    assert_includes feedback(4), "This conversation is no longer followed"
    assert_equal 1, @bridge.inputs.length
    assert_nil @state.read["pending_update"]
    assert_equal 5, @state.read.fetch("offset")
    assert_equal "conversation-1", @state.read.fetch("routes").fetch("1:0").fetch("current")
    assert_equal "conversation-2", @state.read.fetch("routes").fetch("-10:4:1").fetch("current")
  end

  def test_queued_results_keep_their_snapshot_while_the_explicit_copy_uses_the_new_destination
    @state.change { |document| document["retry_at"] = @now + 1_000 }
    @bridge.turn_rows["conversation-1"] = [turn(0, "Queued report")]
    @runtime.tick
    key = "turn:conversation-1:turn-0:conversation-1-variant-0"
    original = @state.read.fetch("deliveries").fetch(key)
    @runtime.consume(telegram_message(3, "/deliver #{task_id(1)} -10:4"))
    assert_equal original, @state.read.fetch("deliveries").fetch(key)
    @now += 1_001
    drain
    assert_equal ["-10", "1"], result_sends("Queued report").map { |row| row.fetch(:chat_id) }.sort
  end

  def test_partial_and_sending_receipts_are_never_retargeted
    @state.change { |document| document["retry_at"] = @now + 1_000 }
    @bridge.turn_rows["conversation-1"] = [turn(0, "Queued report")]
    @runtime.tick
    key = "turn:conversation-1:turn-0:conversation-1-variant-0"
    @state.change { |document| document.fetch("deliveries").fetch(key).merge!("part" => 1, "message_ids" => [500]) }
    original = @state.read.fetch("deliveries").fetch(key)
    @runtime.consume(telegram_message(3, "/deliver #{task_id(1)} -10:4"))
    assert_equal original, @state.read.fetch("deliveries").fetch(key)
    @state.change { |document| document.fetch("deliveries").fetch(key)["status"] = "sending" }
    @runtime.consume(telegram_message(4, "/deliver #{task_id(1)} 1:0"))
    assert_equal "1", @state.read.fetch("deliveries").fetch(key).fetch("chat_id")
    assert_equal "sending", @state.read.fetch("deliveries").fetch(key).fetch("status")
    @runtime = runtime
    assert_equal "uncertain", @state.read.fetch("deliveries").fetch(key).fetch("status")
    assert_empty result_sends("Queued report")
  end

  def test_uncertain_copy_is_not_resent_by_repeated_command_or_restart
    drain
    @bridge.turn_rows["conversation-1"] = [turn(0, "Uncertain report")]
    @runtime.consume(telegram_message(3, "/deliver #{task_id(1)} -10:4"))
    @client.failure = Rho::IngressTelegram::Client::Unavailable.new(reason: :read, ambiguous: true)
    @now += 60
    @runtime.tick
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @runtime = runtime
    @runtime.consume(telegram_message(4, "/deliver #{task_id(1)} -10:4"))
    drain
    copy = @state.read.fetch("deliveries").values.find { |entry| entry["result_copy"] }
    assert_equal "uncertain", copy.fetch("status")
    assert_equal 1, result_sends("Uncertain report").length
    assert_equal "-10", copy.fetch("chat_id")
  end

  def test_source_replacement_or_read_loss_discards_unsent_copy
    @bridge.turn_rows["conversation-1"] = [turn(0, "Old report")]
    drain
    @client.calls.clear
    @runtime.consume(telegram_message(3, "/deliver #{task_id(1)} -10:4"))
    @bridge.turn_rows.fetch("conversation-1").first["variant_public_id"] = "replacement"
    drain
    assert_empty result_sends("Old report")
    refute @state.read.fetch("deliveries").values.any? { |entry| entry["result_copy"] }
    @runtime.consume(telegram_message(4, "/deliver #{task_id(1)} -10:4"))
    @bridge.read_failure = Rho::Core::Refused.new("no longer readable", status: 404, code: "not_found")
    drain
    assert_empty result_sends("Old report")
    refute @state.read.fetch("deliveries").values.any? { |entry| entry["result_copy"] }
  end

  def test_cross_chat_steering_acknowledgement_does_not_link_an_implicit_source_reply
    @runtime.consume(telegram_message(3, "/deliver #{task_id(1)} -10:4"))
    @runtime.consume(telegram_message(4, "/steer #{task_id(1)} keep it concise", chat: -10, topic: 4))
    drain
    acknowledgement = result_sends("additional instruction is accepted").fetch(0)
    refute acknowledgement.key?(:reply_parameters)
    message_key = @state.read.fetch("messages").find { |_key, value| value == "delivery:control:4" }.first
    message_id = message_key.split(":").last.to_i
    @runtime.consume(telegram_message(5, "Now read private notes", chat: -10, topic: 4, reply_to: message_id))
    assert_includes feedback(5), "cannot continue its source conversation"
    assert_equal 2, @bridge.inputs.length
  end

  def test_future_spoken_reply_uses_destination_but_manual_copy_does_not_synthesize_again
    @settings = Rho::IngressTelegram::Settings.new({ "owner_id" => 1, "speech_model" => "vendor/speech" },
      env: { "RHO_TELEGRAM_BOT_TOKEN" => "fake-token" })
    @state.change { |document| document.fetch("routes").fetch("1:0")["voice"] = "all" }
    @runtime = runtime
    speech_calls = []
    @bridge.define_singleton_method(:speech_start) do |**fields|
      speech_calls << fields
      { "id" => "speech-1", "status" => "completed", "media" => {
        "filename" => "reply.ogg", "content_type" => "audio/ogg", "byte_size" => 5, "inference_request_public_id" => "speech-1",
      } }
    end
    @bridge.define_singleton_method(:media_bytes) { |_, **| "voice" }
    @client.define_singleton_method(:upload) { |method, params, **fields| call(method, params.merge(fields)) }
    @runtime.consume(telegram_message(3, "/deliver #{task_id(1)} -10:4"))
    @bridge.turn_rows["conversation-1"] = [turn(0, "Spoken report")]
    drain
    voice = @client.calls.find { |method, _| method == "sendVoice" }.last
    assert_equal "-10", voice.fetch(:chat_id)
    assert_equal 4, voice.fetch(:message_thread_id)
    refute voice.key?(:reply_parameters)
    assert_equal "workspace-home", speech_calls.fetch(0).fetch(:workspace_public_id)
    @runtime.consume(telegram_message(4, "/deliver #{task_id(1)} 1:0"))
    drain
    assert_equal 1, speech_calls.length
  end

  def test_removing_destination_group_blocks_its_queued_result
    @bridge.turn_rows["conversation-1"] = [turn(0, "Held report")]
    @runtime.consume(telegram_message(3, "/deliver #{task_id(1)} -10:4"))
    @state.change { |document| document.fetch("access")["allowed_chats"] = [] }
    drain
    assert_empty result_sends("Held report")
    copy = @state.read.fetch("deliveries").values.find { |entry| entry["result_copy"] }
    assert_equal "pending", copy.fetch("status")
  end

  private

    def task_id(number) = self.class.task_id(number)
    def derived_events(position, input: "derived", sequence: 1)
      [event(sequence, "input_accepted", "input_public_id" => input, "origin" => "task_result", "run_public_id" => "loop-1"),
        event(sequence + 1, "input_materialized", "input_public_id" => input, "turn_public_id" => "turn-#{position}"),
        event(sequence + 2, "turn_status", "turn_public_id" => "turn-#{position}", "run_public_id" => "#{input}-loop")]
    end
    def unrelated_events(sequences)
      sequences.map { |sequence| event(sequence, "input_accepted", "input_public_id" => "unrelated-#{sequence}", "origin" => "person") }
    end
    def event(sequence, type, payload)
      { "sequence" => sequence, "cursor" => sequence.to_s, "type" => type, "payload" => payload }
    end
    def feedback(id) = @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")
    def drain
      8.times do
        @now += 60
        @runtime.tick
      end
    end
    def result_sends(text)
      @client.calls.filter_map { |method, fields| fields if method == "sendMessage" && fields.fetch(:text, "").include?(text) }
    end
end
