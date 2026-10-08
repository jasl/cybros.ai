require "support/runtime"

class TelegramInputBatchTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_zero_submits_each_text_during_consume_without_a_timer_pass
    @settings = Rho::IngressTelegram::Settings.new({ "owner_id" => 1, "input_debounce_seconds" => 0 },
      env: { "RHO_TELEGRAM_BOT_TOKEN" => "fake-token" })
    @runtime.configure(settings: @settings, default_model: nil)
    @runtime.consume(telegram_message(1, "first"))
    assert_equal ["first"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    @runtime.consume(telegram_message(2, "second"))
    assert_equal ["first", "second"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert_empty @state.read.fetch("pending_inputs")
    assert_equal 3, @state.read.fetch("offset")
  end

  def test_successive_corrections_extend_the_quiet_window_and_submit_one_input
    @runtime.consume(telegram_message(1, "Please write a report"))
    @now += 1
    @runtime.consume(telegram_message(2, "Actually, make it a short note"))
    @now += 1
    @runtime.consume(telegram_message(3, "Also include the next steps"))
    @now += 1
    @runtime.tick
    assert_empty @bridge.inputs
    assert_equal 4, @state.read.fetch("offset")
    @now += 1
    @runtime.tick

    assert_equal 1, @bridge.inputs.length
    assert_equal "Please write a report\n\nActually, make it a short note\n\nAlso include the next steps", @bridge.inputs.values.first.fetch(:text)
    assert_equal "speaker-1", @bridge.inputs.values.first.fetch(:speaker)
    assert_empty @state.read.fetch("pending_inputs")
    assert_equal ["input-1"], @state.read.fetch("requests").values.map { |row| row.fetch("input_id") }.uniq
    assert_equal ["loop-1"], @state.read.fetch("requests").values.map { |row| row.fetch("run_id") }.uniq
  end

  def test_restart_preserves_the_remaining_quiet_window_and_every_source_message
    @runtime.consume(telegram_message(1, "Start here"))
    @now += 1
    @runtime.consume(telegram_message(2, "And here"))
    @runtime = runtime
    @runtime.tick
    assert_empty @bridge.inputs
    @now += 2
    @runtime.tick

    assert_equal ["Start here\n\nAnd here"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    @runtime.consume(telegram_message(3, "/stop", reply_to: 1, reply_user: 1))
    @runtime.consume(telegram_message(4, "/stop", reply_to: 2, reply_user: 1))
    assert_equal ["loop-1", "loop-1"], @bridge.stops
  end

  def test_live_ten_second_setting_extends_new_messages_without_replacing_saved_deadlines
    @runtime.consume(telegram_message(1, "first"))
    assert_equal 1002, @state.read.fetch("pending_inputs").fetch("1").fetch("ready_at")
    @settings = Rho::IngressTelegram::Settings.new({ "owner_id" => 1, "input_debounce_seconds" => 10 },
      env: { "RHO_TELEGRAM_BOT_TOKEN" => "fake-token" })
    @runtime.configure(settings: @settings, default_model: nil)
    @runtime = runtime
    assert_equal 1002, @state.read.fetch("pending_inputs").fetch("1").fetch("ready_at")
    @now += 1
    @runtime.consume(telegram_message(2, "follow-up"))
    assert_equal [1011, 1011], @state.read.fetch("pending_inputs").values.map { |row| row.fetch("ready_at") }
    @now += 9
    @runtime.tick
    assert_empty @bridge.inputs
    @now += 1
    @runtime.tick
    assert_equal "first\n\nfollow-up", @bridge.inputs.values.first.fetch(:text)
  end

  def test_group_followups_during_the_window_need_no_second_mention_and_preserve_sender
    @runtime.consume(telegram_message(1, "@rho_bot do this", user: 2, chat: -10,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    @now += 1
    @runtime.consume(telegram_message(2, "also that", user: 2, chat: -10))
    @runtime.consume(telegram_message(3, "someone else's words", chat: -10))
    @now += 2
    @runtime.tick

    assert_equal 1, @bridge.inputs.length
    input = @bridge.inputs.values.first
    assert_equal "@rho_bot do this\n\nalso that", input.fetch(:text)
    assert_equal "speaker-2", input.fetch(:speaker)
    assert input.fetch(:isolated)
    refute_includes input.fetch(:tool_names), "bash"
    @runtime.consume(telegram_message(4, "unaddressed after the burst", user: 2, chat: -10))
    @now += 2
    @runtime.tick
    assert_equal 1, @bridge.inputs.length
  end

  def test_different_requesters_and_topics_have_independent_deadlines
    @runtime.consume(telegram_message(1, "@rho_bot A", user: 2, chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    @now += 1
    @runtime.consume(telegram_message(2, "@rho_bot B", chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    @runtime.consume(telegram_message(3, "@rho_bot C", user: 2, chat: -10, topic: 5,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    @now += 1
    @runtime.tick
    assert_equal ["@rho_bot A"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    @now += 1
    @runtime.tick
    assert_equal ["@rho_bot A", "@rho_bot B", "@rho_bot C"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert_equal 3, @bridge.inputs.values.map { |row| row.fetch(:conversation_id) }.uniq.length
  end

  def test_model_selection_is_a_batch_boundary
    @runtime.consume(telegram_message(1, "first model"))
    @runtime.consume(telegram_message(2, "/model vendor/model"))
    @now += 1
    @runtime.consume(telegram_message(3, "second model"))
    @now += 1
    @runtime.tick
    assert_equal ["first model"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    @now += 1
    @runtime.tick
    assert_equal [nil, "vendor/model"], @bridge.inputs.values.map { |row| row[:model] }
  end

  def test_commands_bypass_debounce_and_stop_removes_only_the_referenced_message
    @runtime.consume(telegram_message(1, "keep this"))
    @now += 1
    @runtime.consume(telegram_message(2, "cancel this"))
    @runtime.consume(telegram_message(3, "/status"))
    assert @state.read.fetch("deliveries").key?("control:3")
    @runtime.consume(telegram_message(4, "/stop", reply_to: 2, reply_user: 1))
    @now += 2
    @runtime.tick
    assert_equal ["keep this"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert @state.read.fetch("requests").fetch("telegram:42:2:input").fetch("retired")
    assert_empty @bridge.stops
  end

  def test_new_discards_unadmitted_text_without_moving_it_to_the_new_conversation
    @runtime.consume(telegram_message(1, "do not run this"))
    @runtime.consume(telegram_message(2, "/new"))
    @runtime.consume(telegram_message(3, "new conversation"))
    @now += 2
    @runtime.tick
    assert_equal ["new conversation"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert_equal "conversation-2", @bridge.inputs.values.first.fetch(:conversation_id)
    assert @state.read.fetch("requests").fetch("telegram:42:1:input").fetch("retired")
  end

  def test_lost_acceptance_freezes_the_batch_before_a_later_message_arrives
    attempts = []
    submit = @bridge.method(:submit)
    @bridge.define_singleton_method(:submit) do |id, **fields|
      attempts << fields
      submit.call(id, **fields)
    end
    @runtime.consume(telegram_message(1, "first"))
    @now += 1
    @runtime.consume(telegram_message(2, "correction"))
    @now += 2
    @bridge.fail_input = true
    @runtime.tick
    @runtime.consume(telegram_message(3, "later request"))
    @runtime = runtime
    @runtime.tick
    assert_equal attempts.first, attempts.last
    @now += 2
    @runtime.tick

    assert_equal ["first\n\ncorrection", "later request"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert_empty @state.read.fetch("pending_inputs")
    assert_equal ["input-1", "input-1", "input-2"], @state.read.fetch("requests").values.map { |row| row.fetch("input_id") }
  end

  def test_new_during_submission_preserves_the_original_acceptance_and_task_route
    submit = @bridge.method(:submit)
    runtime = @runtime
    change_route = telegram_message(2, "/new")
    @bridge.define_singleton_method(:submit) do |id, **fields|
      runtime.consume(change_route)
      submit.call(id, **fields)
    end
    @runtime.consume(telegram_message(1, "already submitting"))
    @now += 2
    @runtime.tick

    request = @state.read.fetch("requests").fetch("telegram:42:1:input")
    assert_equal "input-1", request.fetch("input_id")
    assert_equal "conversation-1", request.fetch("conversation_id")
    refute request["retired"]
    assert_equal "conversation-2", @state.read.fetch("routes").fetch("1:0").fetch("current")
    assert_empty @state.read.fetch("pending_inputs")
  end

  def test_stop_during_tool_selection_cannot_reappear_in_the_submitted_text
    @runtime.consume(telegram_message(1, "keep", user: 2, chat: 2))
    @runtime.consume(telegram_message(2, "cancel me", user: 2, chat: 2))
    select_tools = @bridge.method(:read_only_tool_names)
    runtime = @runtime
    stop = telegram_message(3, "/stop", user: 2, chat: 2, reply_to: 2, reply_user: 2)
    @bridge.define_singleton_method(:read_only_tool_names) do |id, **fields|
      runtime.consume(stop)
      select_tools.call(id, **fields)
    end
    @now += 2
    @runtime.tick

    assert_equal ["keep"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert @state.read.fetch("requests").fetch("telegram:42:2:input").fetch("retired")
    assert_empty @state.read.fetch("pending_inputs")
  end

  def test_followup_during_tool_selection_keeps_its_new_quiet_deadline
    @runtime.consume(telegram_message(1, "first", user: 2, chat: 2))
    select_tools = @bridge.method(:read_only_tool_names)
    runtime = @runtime
    following = telegram_message(2, "follow-up", user: 2, chat: 2)
    @bridge.define_singleton_method(:read_only_tool_names) do |id, **fields|
      runtime.consume(following)
      select_tools.call(id, **fields)
    end
    @now += 2
    @runtime.tick
    # The original window has closed, so this is a new batch and must remain
    # separate even while the previous batch selects its tools.
    assert_equal ["first"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert_equal ["follow-up"], @state.read.fetch("pending_inputs").values.map { |row| row.fetch("text") }
    @now += 2
    @runtime.tick
    assert_equal ["first", "follow-up"], @bridge.inputs.values.map { |row| row.fetch(:text) }
  end

  def test_revoked_access_retires_the_whole_unconfirmed_batch_before_reallowing
    @runtime.consume(telegram_message(1, "first", user: 2, chat: 2))
    @runtime.consume(telegram_message(2, "correction", user: 2, chat: 2))
    @now += 2
    @bridge.fail_input = true
    @runtime.tick
    @runtime.consume(telegram_message(3, "/access users remove 2"))
    @runtime.tick
    @runtime.consume(telegram_message(4, "/access users add 2"))
    @runtime.tick

    assert_equal ["first\n\ncorrection"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert_empty @state.read.fetch("pending_inputs")
    assert @state.read.fetch("requests").fetch("telegram:42:2:input").fetch("retired")
  end

  def test_stop_during_submission_preserves_the_receipt_and_reports_its_actual_state
    submit = @bridge.method(:submit)
    runtime = @runtime
    stop = telegram_message(2, "/stop", reply_to: 1, reply_user: 1)
    @bridge.define_singleton_method(:submit) do |id, **fields|
      runtime.consume(stop)
      submit.call(id, **fields)
    end
    @runtime.consume(telegram_message(1, "already submitting"))
    @now += 2
    @runtime.tick

    assert_equal "input-1", @state.read.fetch("requests").fetch("telegram:42:1:input").fetch("input_id")
    assert_includes @client.calls.filter_map { |_method, params| params[:text] }.join, "Message admission has started"
    assert_empty @bridge.stops
    assert_empty @state.read.fetch("pending_inputs")
  end

  def test_expired_unconfirmed_batch_is_not_replayed_after_restart
    @runtime.consume(telegram_message(1, "old"))
    @now += 24 * 60 * 60
    @runtime = runtime
    @runtime.tick
    assert_empty @bridge.inputs
    assert_empty @state.read.fetch("pending_inputs")
    assert_includes @client.calls.filter_map { |_method, params| params[:text] }.join, "recovery window expired"
  end

  def test_archived_conversation_does_not_keep_an_unconfirmed_submission_past_its_recovery_window
    @runtime.consume(telegram_message(1, "unknown outcome"))
    @now += 2
    @bridge.fail_input = true
    @runtime.tick
    assert @state.read.fetch("pending_inputs").fetch("1").fetch("submission")
    @bridge.define_singleton_method(:conversation) { |_id, **| { "archived_at" => "2026-10-09T00:00:00Z" } }
    @now += 24 * 60 * 60
    @runtime = runtime
    @runtime.tick
    assert_empty @state.read.fetch("pending_inputs")
    assert_includes @client.calls.filter_map { |_method, params| params[:text] }.join, "recovery window expired"
  end

  def test_old_unfinished_admission_is_not_silently_forgotten
    @state.change { |document| document["pending_media"] = { "old" => { "text" => "unfinished" } } }
    error = assert_raises(Rho::StateError) { @state.read }
    assert_includes error.message, "previous version"
    assert_includes error.message, "do not delete"
  end
end
