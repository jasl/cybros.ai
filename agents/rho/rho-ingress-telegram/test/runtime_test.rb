require "support/runtime"

class TelegramRuntimeTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_inherited_history_advances_the_cursor_without_resending_parent_answers
    receive(telegram_message(1, "/new"))
    @bridge.turn_rows["conversation-1"] = [turn(0, "Parent answer").merge("inherited" => true)]
    @runtime.tick

    assert_equal 0, @state.read.fetch("routes").dig("1:0", "conversations", "conversation-1", "position")
    refute @state.read.fetch("deliveries").key?("turn:conversation-1:turn-0:conversation-1-variant-0")
    @bridge.turn_rows["conversation-1"] << turn(1, "New answer")
    @now += Rho::IngressTelegram::Runtime::RECONCILE_INTERVAL
    @runtime.tick
    assert_equal 1, @state.read.fetch("routes").dig("1:0", "conversations", "conversation-1", "position")
    refute @client.calls.any? { |_method, params| params[:text].to_s.include?("Parent answer") }
    assert @client.calls.any? { |_method, params| params[:text].to_s.include?("New answer") }
  end

  def test_lost_input_reply_retries_same_owner_and_key_after_restart
    @bridge.fail_input = true
    assert_raises(Rho::ConnectionError) { receive(telegram_message(1, "你好")) }
    assert_equal 2, @state.read.fetch("offset")
    assert @state.read.fetch("pending_inputs").fetch("1").key?("submission")
    assert_equal 1, @bridge.inputs.length
    @runtime = runtime
    receive(telegram_message(1, "你好"))
    receive(telegram_message(1, "你好"))
    assert_equal 2, @state.read.fetch("offset")
    assert_equal 1, @bridge.opened.length
    assert_equal 1, @bridge.inputs.length
    assert_equal 1, @bridge.speakers.length
    assert_equal "speaker-1", @bridge.inputs.values.first.fetch(:speaker)
  end

  def test_an_older_staged_input_recovers_before_a_different_incoming_input
    @bridge.fail_input = true
    assert_raises(Rho::ConnectionError) { receive(telegram_message(1, "Original request")) }
    @now += 601
    @runtime = runtime
    later = telegram_message(2, "Later request", date: @now.to_i)
    receive(later)

    assert_equal "input-1", @state.read.fetch("requests").fetch("telegram:42:1:input").fetch("input_id")
    assert_equal ["Original request"], @bridge.inputs.values.map { |input| input.fetch(:text) }
    assert_equal 3, @state.read.fetch("offset")
    assert_equal ["2"], @state.read.fetch("pending_inputs").keys
    receive(later)
    assert_equal ["Original request", "Later request"], @bridge.inputs.values.map { |input| input.fetch(:text) }
    assert_equal 3, @state.read.fetch("offset")
  end

  def test_pending_update_recovery_retires_unknown_admission_when_requester_access_is_removed
    assert_revoked_pending_request { |access| access["allowed_users"] = [] }
  end

  def test_pending_update_recovery_retires_unknown_admission_when_chat_access_is_removed
    assert_revoked_pending_request { |access| access["allowed_chats"] = [] }
  end

  def test_pending_update_recovery_retires_unknown_admission_when_requester_is_ignored
    assert_revoked_pending_request { |access| access["ignored_users"] = ["2"] }
  end

  def test_group_speakers_have_separate_tasks_and_observation_never_replies
    receive(telegram_message(1, "background", chat: -10, topic: 4))
    assert_empty @bridge.inputs
    receive(telegram_message(2, "😀 @rho_bot help", chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 3, "length" => 8 }]))
    @client.admin = true
    receive(telegram_message(3, "/observe on", chat: -10, topic: 4))
    receive(telegram_message(4, "旁听背景", user: 2, chat: -10, topic: 4))
    receive(telegram_message(5, "@rho_bot next", user: 2, chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    assert_equal 2, @bridge.opened.length
    assert_equal 1, @bridge.memory_anchors.length
    assert_equal [false, true, false], @bridge.inputs.values.map { |row| row.fetch(:observe) }
    assert_equal ["speaker-1", "speaker-2", "speaker-2"], @bridge.inputs.values.map { |row| row.fetch(:speaker) }
    assert_equal 3, @bridge.inputs.values.map { |row| row.fetch(:conversation_id) }.uniq.length
    assert_equal %w[-10:4:1 -10:4:2], @state.read.fetch("routes").keys
    assert_equal "memory-1", @state.read.fetch("rooms").fetch("-10:4").fetch("conversation_id")
    assert_equal "旁听背景", @bridge.inputs.values.last.fetch(:inline).first.fetch("text")
    refute @state.read.fetch("deliveries").key?("control:4")
    receive(telegram_message(6, "@rho_bot topic", chat: -10, topic: 5,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    assert_equal 3, @bridge.opened.length
    assert_equal 2, @bridge.memory_anchors.length
  end

  def test_observe_requires_delivery_capability_and_the_configured_owner
    receive(telegram_message(1, "/observe on", chat: -10))
    refute @state.read.fetch("rooms").dig("-10:0", "observe")
    @client.admin = true
    receive(telegram_message(2, "/observe on", chat: -10, user: 2))
    refute @state.read.fetch("rooms").dig("-10:0", "observe")
    receive(telegram_message(3, "/observe on", chat: -10))
    assert @state.read.fetch("rooms").dig("-10:0", "observe")
    receive(telegram_message(4, "/observe off", chat: -10))
    refute @state.read.fetch("rooms").dig("-10:0", "observe")
    @client.admin = false
    @client.privacy_disabled = true
    receive(telegram_message(5, "/observe on", chat: -10))
    assert @state.read.fetch("rooms").dig("-10:0", "observe")
  end

  def test_unallowed_and_stale_input_never_registers_or_executes
    receive(telegram_message(1, "run", user: 99))
    receive(telegram_message(2, "run", chat: -99))
    receive(telegram_message(3, "run", date: 1))
    receive(telegram_message(4, "/new", date: 1))
    receive(telegram_message(5, "/new@somebody_else"))
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_empty @bridge.speakers
    assert_equal 6, @state.read.fetch("offset")
  end

  def test_async_completion_is_a_new_formal_reply_and_old_conversation_remains_followed
    receive(telegram_message(1, "start"))
    receive(telegram_message(2, "/new"))
    @bridge.turn_rows["conversation-1"] = [turn(1, "Original answer"), turn(2, "Later background answer")]
    @runtime.tick
    deliveries = @state.read.fetch("deliveries").select { |key, _entry| key.start_with?("turn:") }
    assert_equal ["Original answer", "Later background answer"], deliveries.values.map { |entry| entry.fetch("text") }
    @runtime = runtime
    @runtime.tick
    @now += 1
    @runtime.tick
    assert_equal ["Original answer", "Later background answer"], @client.calls.filter_map { |method, fields|
      fields[:text] if method == "sendMessage" && ["Original answer", "Later background answer"].include?(fields[:text])
    }
    assert_equal 2, @state.read.fetch("routes").fetch("1:0").fetch("conversations").length
  end

  def test_running_turn_keeps_cursor_behind_it_until_it_settles
    receive(telegram_message(1, "start"))
    @bridge.turn_rows["conversation-1"] = [turn(1, "", status: "running")]
    @runtime.tick
    assert_nil @state.read.fetch("routes").dig("1:0", "conversations", "conversation-1", "position")
    @bridge.turn_rows["conversation-1"] = [turn(1, "complete")]
    @bridge.current["sequence"] += 1
    @now += Rho::IngressTelegram::Runtime::RECONCILE_INTERVAL
    @runtime.tick
    assert_equal 1, @state.read.fetch("routes").dig("1:0", "conversations", "conversation-1", "position")
  end

  def test_controls_work_while_running_and_decisions_keep_exact_child_task
    receive(telegram_message(1, "start"))
    @bridge.pending_rows = [{ "workspace_public_id" => "workspace-home", "run_public_id" => "child-loop", "task_key" => "dangerous-tool", "kind" => "approval",
      "question" => "Run the reviewed command?" }]
    @runtime.tick
    id = @state.read.fetch("questions").keys.fetch(0)
    receive(telegram_message(2, "/approve #{id}"))
    assert_equal [["approve", "child-loop", "dangerous-tool", "workspace-home"]], @bridge.decisions
    receive(telegram_message(3, "/approve #{id}"))
    assert_equal 1, @bridge.decisions.length
    receive(telegram_message(4, "/stop"))
    assert_equal [["loop-1", "run", "workspace-home"]], @bridge.stop_calls
  end

  def test_old_draft_stop_does_not_cancel_the_next_execution
    receive(telegram_message(1, "start"))
    @state.change do |document|
      document.fetch("routes").fetch("1:0")["draft"] = {
        "id" => 77, "conversation_id" => "conversation-1", "run_id" => "old-loop",
      }
    end
    receive("update_id" => 2, "stopped_message_generation" => {
      "chat" => { "id" => 1, "type" => "private" }, "draft_id" => 77,
    })
    assert_empty @bridge.stops
    @bridge.current["run_public_id"] = "old-loop"
    receive("update_id" => 3, "stopped_message_generation" => {
      "chat" => { "id" => 1, "type" => "private" }, "draft_id" => 77,
    })
    assert_equal ["old-loop"], @bridge.stops
  end

  def test_lost_stop_response_does_not_reapply_stop_after_restart
    receive(telegram_message(1, "start"))
    @bridge.fail_stop = true
    assert_raises(Rho::ConnectionError) { receive(telegram_message(2, "/stop")) }
    @runtime = runtime
    @bridge.current["run_public_id"] = "later-unrelated-loop"
    receive(telegram_message(2, "/stop"))
    assert_equal [["loop-1", "run", "workspace-home"]], @bridge.stop_calls
    assert_includes @state.read.fetch("deliveries").fetch("control:2").fetch("text"), "not repeated"
    assert_equal 3, @state.read.fetch("offset")
  end

  def test_revoking_access_rejects_future_private_input_but_delivers_already_accepted_work
    receive(telegram_message(1, "start", user: 2))
    receive(telegram_message(2, "/access users remove 2"))
    receive(telegram_message(3, "future input", user: 2))
    @bridge.turn_rows["conversation-1"] = [turn(0, "Private result")]
    @state.change { |document| document.fetch("deliveries").clear }
    @runtime = runtime
    @runtime.tick
    assert_equal 1, @bridge.inputs.length
    assert_equal ["Private result"], @client.calls.filter_map { |method, params| params[:text] if method == "sendMessage" }
    assert_empty @bridge.stops
  end

  def test_registration_guard_keeps_the_previous_bot_and_does_not_accept_another
    assert_raises(Rho::ConfigurationError) { @runtime.identify("id" => 99, "username" => "other_bot") }
    receive(telegram_message(1, "hello"))
    assert @bridge.inputs.key?("telegram:42:1:input")
    assert_equal "42", @state.read.fetch("bot_id")
  end

  def test_unknown_user_can_receive_only_the_explicit_private_start_guide
    receive(telegram_message(1, "/start", user: 99))
    @runtime.tick
    assert_equal 1, @client.calls.length
    assert_includes @client.calls.first.last.fetch(:text), "user ID: 99"
    assert_empty @bridge.inputs
  end

  def test_first_kernel_turn_is_position_zero_and_must_be_delivered
    receive(telegram_message(1, "start"))
    @bridge.turn_rows["conversation-1"] = [turn(0, "The first answer")]
    @runtime.tick
    assert @client.calls.any? { |method, fields| method == "sendMessage" && fields[:text] == "The first answer" }
    assert_equal 0, @state.read.fetch("routes").dig("1:0", "conversations", "conversation-1", "position")
  end

  def test_blocked_input_is_reported_once_even_without_an_run
    receive(telegram_message(1, "start"))
    @bridge.current = { "status" => "blocked", "blocked_input_public_id" => "blocked-input" }
    2.times { @runtime.tick }
    notices = @state.read.fetch("deliveries").select { |key, _entry| key.start_with?("blocked:") }
    assert_equal 1, notices.length
    assert_equal 1, @client.calls.count { |method, fields| method == "sendMessage" && fields[:text].include?("queued request needs attention") }
  end

  def test_unknown_slash_commands_are_mechanical_and_never_sent_to_the_model
    receive(telegram_message(1, "/something_123"))
    receive(telegram_message(2, "/foo.bar"))
    assert_empty @bridge.inputs
    assert_includes @state.read.fetch("deliveries").fetch("control:1").fetch("text"), "Unknown command"
    assert_includes @state.read.fetch("deliveries").fetch("control:2").fetch("text"), "Unknown command"
  end

  private

    def assert_revoked_pending_request
      @bridge.fail_input = true
      update = telegram_message(1, "/remind in 2d Original request", user: 2, chat: -10)
      assert_raises(Rho::ConnectionError) { receive(update) }
      @state.change { |document| yield(document.fetch("access")) }
      @bridge.define_singleton_method(:submit) { |*| raise "revoked requester must not be resubmitted" }
      @now += 601
      @runtime = runtime
      receive(update)

      assert_equal 1, @bridge.inputs.length
      assert @state.read.fetch("requests").fetch("telegram:42:1:input").fetch("retired")
      assert_nil @state.read["pending_update"]
      assert_equal 2, @state.read.fetch("offset")
      assert_empty @state.read.fetch("deliveries")
    end
end
