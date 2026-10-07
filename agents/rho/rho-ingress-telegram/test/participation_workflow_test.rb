require "support/participation"

class TelegramParticipationWorkflowTest < Minitest::Test
  include TelegramParticipationSupport

  def test_mode_defaults_to_assistant_and_is_owner_changed_per_topic
    group_message(1, "/mode", user: 2)
    assert_includes @state.read.fetch("deliveries").fetch("control:1").fetch("text"), "Mode: assistant"
    group_message(2, "/mode active", user: 2)
    assert_includes @state.read.fetch("deliveries").fetch("control:2").fetch("text"), "Only the bot owner"
    assert_empty @state.read.fetch("rooms")

    group_message(3, "/mode active")
    assert_equal "active", group_room.fetch("mode")
    assert_includes @state.read.fetch("deliveries").fetch("control:3").fetch("text"), "paused"
    refute group_room["observe"]
    assert_empty @bridge.opened
    assert_empty @bridge.inference_requests
    @runtime.consume(telegram_message(4, "/mode active"))
    assert_includes @state.read.fetch("deliveries").fetch("control:4").fetch("text"), "only available in groups"
    @runtime.consume(telegram_message(5, "/mode", chat: -10, topic: 5))
    assert_includes @state.read.fetch("deliveries").fetch("control:5").fetch("text"), "Mode: assistant"
  end

  def test_burst_is_coalesced_and_success_is_plain_then_recorded_without_a_task
    enable_participation
    group_message(3, "Does anyone know a useful shortcut?", user: 2)
    advance(3)
    assert_empty @bridge.inference_requests
    group_message(4, "A concise answer would help.", user: 2)
    advance(5)
    assert_equal 1, @bridge.inference_requests.length
    call = @bridge.participation_starts.fetch(0)
    assert_includes call.fetch(:prompt), "Does anyone know a useful shortcut?"
    assert_includes call.fetch(:prompt), "A concise answer would help."
    assert_equal "vendor/default", call.fetch(:model)
    assert_equal({}, call.fetch(:configuration))
    finish_participation
    advance
    assert_includes sent_texts, "A short useful reply"
    delivered = @client.calls.find { |method, fields| method == "sendMessage" && fields[:text] == "A short useful reply" }.last
    refute delivered.key?(:parse_mode)
    refute delivered.key?(:reply_parameters)
    assert_empty @bridge.participation_records
    advance
    assert_equal 1, @bridge.participation_records.length
    assert_equal "A short useful reply", @bridge.participation_records.values.first.fetch(:text)
    assert_empty @state.read.fetch("requests")
    assert_empty @state.read.fetch("routes")
    assert @bridge.inputs.values.all? { |row| row.fetch(:observe) }
    advance(120)
    assert_equal 1, @bridge.inference_requests.length, "own assistant history never triggers another judgment"
  end

  def test_only_future_observation_triggers_and_source_waits_for_materialization
    @client.admin = true
    group_message(1, "/observe on")
    group_message(2, "Older background", user: 2)
    group_message(3, "/mode active")
    advance(30)
    assert_empty @bridge.inference_requests
    group_message(4, "New background", user: 2)
    @bridge.participation_ready = false
    advance
    assert_empty @bridge.inference_requests
    @bridge.participation_ready = true
    advance(30)
    assert_equal 1, @bridge.inference_requests.length
  end

  def test_explicit_request_cancels_an_old_candidate_without_rejudging_its_source
    enable_participation
    group_message(3, "Maybe rho can add a thought.", user: 2)
    advance
    shot = @bridge.inference_requests.values.fetch(0)
    group_message(4, "@rho_bot please read this", user: 2,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }])
    advance
    assert_equal [[shot.fetch("id"), "workspace-home"]], @bridge.participation_cancels
    @bridge.current["status"] = "completed"
    advance(120)
    assert_equal 1, @bridge.inference_requests.length
    refute_includes sent_texts, "A short useful reply"
    assert_equal %w[read ls find grep delegate_task code wait ask], @bridge.inputs.values.last.fetch(:tool_names)
  end

  def test_completed_quiet_invalid_and_truncated_answers_consume_each_batch
    enable_participation
    outputs = [JSON.generate("decision" => "quiet", "text" => ""), "not JSON",
      JSON.generate("decision" => "reply", "text" => "x" * 1201),
      JSON.generate("decision" => "reply", "text" => "cut off"), "null", "[]",
      JSON.generate("decision" => "reply", "text" => 123),
      JSON.generate("decision" => "reply", "text" => "extra", "unknown" => true)]
    outputs.each_with_index do |text, index|
      group_message(3 + index, "Background #{index}", user: 2)
      advance(30)
      shot = @bridge.inference_requests.values.last
      refute_nil shot
      shot.merge!("status" => "completed", "text" => text)
      shot["finish_quality"] = "output_budget_exhausted" if index == 3
      advance
      advance(30)
      assert_equal index + 1, @bridge.inference_requests.length
    end
    assert_empty @bridge.participation_records
    refute_includes sent_texts, "cut off"
  end

  def test_create_lost_reply_reuses_frozen_envelope_after_restart
    enable_participation
    group_message(3, "An ordinary group discussion", user: 2)
    @bridge.fail_participation_start = true
    advance
    assert_equal 1, @bridge.inference_requests.length
    first = @bridge.participation_starts.fetch(0)
    @bridge.participation_default_model = "vendor/changed"
    @bridge.default_workspace = @bridge.workspace_rows.last
    @runtime = runtime(default_model: "vendor/other")
    advance(30)
    assert_equal first, @bridge.participation_starts.fetch(1)
    assert_equal 1, @bridge.inference_requests.length
  end

  def test_known_active_reply_becomes_the_members_own_read_only_request
    enable_participation
    group_message(3, "A topic for a short reply", user: 2)
    advance
    finish_participation
    advance
    message_id = @client.last_message_id
    advance
    @runtime = runtime
    group_message(4, "Please explain a little more", user: 2, reply_to: message_id)
    request = @bridge.inputs.values.last
    refute request.fetch(:observe)
    assert_equal "speaker-2", request.fetch(:speaker)
    assert_equal %w[read ls find grep delegate_task code wait ask], request.fetch(:tool_names)
    assert_equal "2", @state.read.fetch("requests").values.last.fetch("owner_id")
    assert_equal ["-10:4:2"], @state.read.fetch("routes").keys
  end

  def test_sent_answer_is_recorded_after_mode_off_and_lost_append_reply
    enable_participation
    group_message(3, "A topic", user: 2)
    advance
    finish_participation
    advance
    assert_includes sent_texts, "A short useful reply"
    group_message(4, "/mode assistant")
    @bridge.fail_participation_record = true
    advance
    assert_equal 1, @bridge.participation_records.length
    first = @bridge.record_attempts.fetch(0)
    @runtime = runtime
    advance(30)
    assert_equal [first, first], @bridge.record_attempts
    assert_equal 1, sent_texts.count("A short useful reply")
    assert_equal 1, @bridge.participation_records.length
    assert_nil group_room.fetch("participation")["candidate"]
  end

  def test_judgment_interval_and_successful_send_cooldown
    enable_participation
    group_message(3, "First topic", user: 2)
    advance
    @bridge.inference_requests.values.last.merge!("status" => "completed", "text" => '{"decision":"quiet","text":""}')
    advance
    group_message(4, "Second topic", user: 2)
    advance(19)
    assert_equal 1, @bridge.inference_requests.length
    advance(6)
    assert_equal 2, @bridge.inference_requests.length
    finish_participation
    advance
    advance
    group_message(5, "Third topic", user: 2)
    advance(50)
    assert_equal 2, @bridge.inference_requests.length
    advance
    assert_equal 3, @bridge.inference_requests.length
  end

  def test_running_formal_work_defers_participation_but_waiting_does_not
    enable_participation
    group_message(3, "@rho_bot read this", user: 2,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }])
    group_message(4, "An independent discussion", user: 2)
    advance
    assert_empty @bridge.inference_requests
    @bridge.current["status"] = "waiting"
    advance
    assert_equal 1, @bridge.inference_requests.length
  end

  def test_owner_private_workspace_and_model_are_not_room_defaults
    @runtime.consume(telegram_message(1, "/workspace use Project"))
    @runtime.consume(telegram_message(2, "/model vendor/model"))
    @client.admin = true
    group_message(3, "/observe on")
    group_message(4, "/mode active")
    group_message(5, "A group topic", user: 2)
    advance
    assert_equal "workspace-home", group_room.fetch("workspace_public_id")
    call = @bridge.participation_starts.fetch(0)
    assert_equal "workspace-home", call.fetch(:workspace_public_id)
    assert_equal "vendor/default", call.fetch(:model)
  end

  def test_missing_default_model_consumes_the_batch_without_fallback
    enable_participation
    @bridge.participation_default_model = nil
    group_message(3, "A group topic", user: 2)
    advance
    @bridge.participation_default_model = "vendor/default"
    advance(60)
    assert_empty @bridge.inference_requests
    group_message(4, "A new group topic", user: 2)
    advance
    assert_equal 1, @bridge.inference_requests.length
  end

  def test_observe_off_and_reopen_never_revive_the_previous_candidate
    enable_participation
    group_message(3, "A group topic", user: 2)
    advance
    group_message(4, "/observe off")
    group_message(5, "/observe on")
    advance(30)
    assert_equal 1, @bridge.participation_cancels.length
    assert_equal 1, @bridge.inference_requests.length
    group_message(6, "A new group topic", user: 2)
    advance
    assert_equal 2, @bridge.inference_requests.length
  end

  def test_ignored_then_restored_source_cannot_revive_its_candidate
    enable_participation
    group_message(3, "A group topic", user: 2)
    advance
    @runtime.consume(telegram_message(4, "/ignore add 2", date: @now.to_i))
    @runtime.consume(telegram_message(5, "/ignore remove 2", date: @now.to_i))
    advance(30)
    assert_equal 1, @bridge.participation_cancels.length
    assert_equal 1, @bridge.inference_requests.length
    group_message(6, "A fresh topic after restoration", user: 2)
    advance
    assert_equal 2, @bridge.inference_requests.length
  end

  def test_crash_after_access_commit_cannot_revive_candidate_when_member_is_restored
    enable_participation
    group_message(3, "A group topic", user: 2)
    advance
    change = @state.method(:change)
    crash = true
    @state.define_singleton_method(:change) do |&block|
      result = change.call(&block)
      if crash && read.fetch("access").fetch("ignored_users").include?("2")
        crash = false
        raise Rho::ConnectionError, "process stopped after access reached disk"
      end
      result
    end
    update = telegram_message(4, "/ignore add 2", date: @now.to_i)
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    @runtime = runtime
    @runtime.consume(update)
    @runtime.consume(telegram_message(5, "/ignore remove 2", date: @now.to_i))
    advance(30)
    assert_equal 1, @bridge.participation_cancels.length
    assert_nil group_room.fetch("participation")["candidate"]
  end

  def test_removed_group_cancels_pending_delivery_without_speaking
    enable_participation
    group_message(3, "A group topic", user: 2)
    advance
    finish_participation
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 429, description: "wait", retry_after: 30)
    advance
    key = group_room.fetch("participation").fetch("candidate").fetch("key")
    assert_equal "pending", @state.read.fetch("deliveries").fetch(key).fetch("status")
    calls = sent_texts.count("A short useful reply")
    @runtime.consume(telegram_message(4, "/access chats remove -10", date: @now.to_i))
    advance(30)
    assert_nil @state.read.fetch("deliveries")[key]
    assert_equal calls, sent_texts.count("A short useful reply")
    assert_empty @bridge.participation_records
  end

  def test_unknown_create_that_becomes_invalid_is_never_reposted_for_an_id
    enable_participation
    group_message(3, "A group topic", user: 2)
    @bridge.fail_participation_start = true
    advance
    group_message(4, "/mode assistant")
    @runtime = runtime
    advance(30)
    assert_equal 1, @bridge.participation_starts.length
    assert_empty @bridge.participation_cancels
    assert_nil group_room.fetch("participation")["candidate"]
  end

  def test_known_completed_candidate_is_not_sent_after_restart_past_source_age
    enable_participation
    group_message(3, "A group topic", user: 2)
    advance
    finish_participation
    @runtime = runtime
    advance(601)
    assert_equal 1, @bridge.participation_cancels.length
    refute_includes sent_texts, "A short useful reply"
    assert_empty @bridge.participation_records
  end

  def test_unknown_create_is_not_reposted_after_restart_past_source_age
    enable_participation
    group_message(3, "A group topic", user: 2)
    @bridge.fail_participation_start = true
    advance
    @runtime = runtime
    advance(601)
    assert_equal 1, @bridge.participation_starts.length
    assert_nil group_room.fetch("participation")["candidate"]
  end

  def test_unknown_create_receipt_is_abandoned_after_its_idempotency_window
    @settings = Rho::IngressTelegram::Settings.new({ "owner_id" => 1, "stale_after" => 100_000 },
      env: { "RHO_TELEGRAM_BOT_TOKEN" => "fake-token" })
    @runtime = runtime
    enable_participation
    group_message(3, "A group topic", user: 2)
    @bridge.fail_participation_start = true
    advance
    @runtime = runtime
    advance(86_400)
    assert_equal 1, @bridge.participation_starts.length
    assert_nil group_room.fetch("participation")["candidate"]
  end

  def test_unknown_append_receipt_is_not_reposted_after_its_idempotency_window
    enable_participation
    group_message(3, "A group topic", user: 2)
    advance
    finish_participation
    advance
    @bridge.fail_participation_record = true
    advance
    assert_equal 1, @bridge.record_attempts.length
    @runtime = runtime
    advance(86_400)
    assert_equal 1, @bridge.record_attempts.length
    assert_equal 1, sent_texts.count("A short useful reply")
    assert_nil group_room.fetch("participation")["candidate"]
  end

  def test_ambiguous_send_is_not_repeated_or_recorded_as_spoken
    enable_participation
    group_message(3, "A group topic", user: 2)
    advance
    finish_participation
    @client.failure = Rho::IngressTelegram::Client::Unavailable.new(reason: :read, ambiguous: true)
    advance
    @runtime = runtime
    advance(30)
    advance(60)
    assert_equal 1, sent_texts.count("A short useful reply")
    assert_empty @bridge.participation_records
    assert_nil group_room.fetch("participation")["candidate"]
    assert_equal ["uncertain"], @state.read.fetch("deliveries").values.map { |row| row.fetch("status") }.uniq
  end

  def test_sdk_rejection_consumes_the_batch_and_does_not_crash_the_tick
    enable_participation
    calls = 0
    @bridge.define_singleton_method(:participation_start) do |**|
      calls += 1
      raise CybrosAgent::Api::InvalidRequest.new("no such model", code: "model_unavailable")
    end
    group_message(3, "A group topic", user: 2)
    advance
    advance(60)
    assert_equal 1, calls
    assert_nil group_room.fetch("participation")["candidate"]
  end

  def test_context_rejection_consumes_the_batch_before_a_candidate_exists
    enable_participation
    calls = 0
    @bridge.define_singleton_method(:participation_context) do |*, **|
      calls += 1
      raise CybrosAgent::Api::Forbidden.new("context unavailable", code: "forbidden")
    end
    group_message(3, "A group topic", user: 2)
    advance
    advance(60)
    assert_equal 1, calls
    assert_empty @bridge.inference_requests
  end

  def test_sdk_throttle_and_server_failure_retry_the_same_candidate
    enable_participation
    attempts = []
    errors = [CybrosAgent::Api::RateLimited.new(retry_after: 10), CybrosAgent::Api::ServerError.new("unavailable")]
    @bridge.define_singleton_method(:participation_start) do |**fields|
      attempts << fields
      raise errors.shift unless errors.empty?

      super(**fields)
    end
    group_message(3, "A group topic", user: 2)
    advance
    advance(30)
    advance(30)
    assert_equal 3, attempts.length
    assert_equal 1, attempts.uniq.length
    assert_equal 1, @bridge.inference_requests.length
  end
end
