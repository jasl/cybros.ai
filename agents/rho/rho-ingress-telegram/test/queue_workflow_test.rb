require "support/runtime"

class TelegramQueueWorkflowTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_empty_chat_controls_do_not_open_a_conversation
    @runtime.consume(telegram_message(1, "/queue"))
    @runtime.consume(telegram_message(2, "/status"))

    assert_includes reply(1), "No conversation is open"
    assert_includes reply(2), "idle"
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_empty @bridge.queue_reads
  end

  def test_list_numbers_select_the_listed_uuids_after_other_rows_start_or_positions_change
    open_queue
    @runtime.consume(telegram_message(2, "/queue"))
    assert_match(/1[.)].*first request/, reply(2))
    assert_match(/2[.)].*second request/, reply(2))
    @bridge.queue_rows.fetch("conversation-1").shift
    @bridge.queue_rows.fetch("conversation-1").first["queue_position"] = 0
    @bridge.queue_rows.fetch("conversation-1") << input("replacement", "unrelated", position: 17)

    @runtime.consume(telegram_message(3, "/queue edit 1 wrong target"))
    assert_includes reply(3), "no longer waiting"
    assert_empty @bridge.queue_writes
    @runtime.consume(telegram_message(4, "/queue edit 2 corrected second request"))

    assert_equal [[:edit, "conversation-1", "second", "corrected second request", "workspace-home"]], @bridge.queue_writes
    assert_equal "unrelated", @bridge.queue_rows.fetch("conversation-1").last.fetch("text")
    assert_equal 1, @bridge.inputs.length, "slash commands never become model input"
  end

  def test_edit_keeps_existing_attachments_and_delivery_time_then_cancel_removes_only_its_selected_row
    open_queue
    attachments = [{ "upload_public_id" => "image" }]
    @bridge.queue_rows.fetch("conversation-1").first.merge!("attachments" => attachments,
      "deliver_at" => "2026-10-02T00:00:00Z", "state" => "blocked", "blocked_reason" => "unknown_model")
    @runtime.consume(telegram_message(2, "/queue list"))
    assert_includes reply(2), "blocked"
    assert_includes reply(2), "unknown_model"
    assert_includes reply(2), "attachment"
    @runtime.consume(telegram_message(3, "/queue edit 1 fixed words"))
    @runtime.consume(telegram_message(4, "/queue cancel 2"))

    row = @bridge.queue_rows.fetch("conversation-1").fetch(0)
    assert_equal ["first", "fixed words", attachments, "2026-10-02T00:00:00Z"],
      row.values_at("public_id", "text", "attachments", "deliver_at")
    assert_equal 1, @bridge.queue_rows.fetch("conversation-1").length
    assert_equal [:cancel, "conversation-1", "second", "workspace-home"], @bridge.queue_writes.last
    assert_includes reply(4), "canceled"
  end

  def test_a_new_list_replaces_the_selection_but_reused_kernel_positions_do_not
    open_queue
    @runtime.consume(telegram_message(2, "/queue"))
    @bridge.queue_rows["conversation-1"] = [input("later", "later request", position: 17)]
    @runtime = runtime
    @runtime.consume(telegram_message(3, "/queue cancel 1"))
    assert_includes reply(3), "no longer waiting"
    assert_empty @bridge.queue_writes

    @runtime.consume(telegram_message(4, "/queue"))
    @runtime.consume(telegram_message(5, "/queue cancel 1"))
    assert_equal [[:cancel, "conversation-1", "later", "workspace-home"]], @bridge.queue_writes
  end

  def test_queue_controls_require_a_list_and_do_not_retarget_after_new
    open_queue
    @runtime.consume(telegram_message(2, "/queue cancel 1"))
    assert_includes reply(2), "Use /queue"
    @runtime.consume(telegram_message(3, "/queue"))
    @runtime.consume(telegram_message(4, "/new"))
    @bridge.queue_rows["conversation-2"] = [input("new-input", "new conversation request", position: 17)]
    @runtime.consume(telegram_message(5, "/queue cancel 1"))

    assert_includes reply(5), "Use /queue"
    assert_empty @bridge.queue_writes
    assert_equal "new-input", @bridge.queue_rows.fetch("conversation-2").first.fetch("public_id")
  end

  def test_a_list_replayed_after_reply_enqueue_keeps_the_original_display_and_numbered_targets
    open_queue
    consumed = @state.method(:consumed)
    interrupt = true
    @state.define_singleton_method(:consumed) do |id|
      if id == 2 && interrupt
        interrupt = false
        raise Rho::ConnectionError, "process stopped before update acknowledgement"
      end
      consumed.call(id)
    end
    update = telegram_message(2, "/queue")
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    displayed = reply(2)
    @bridge.queue_rows["conversation-1"] = [input("later", "unrelated later input")]
    @runtime = runtime
    @runtime.consume(update)
    assert_equal displayed, reply(2)
    @runtime.consume(telegram_message(3, "/queue cancel 1"))

    assert_includes reply(3), "no longer waiting"
    assert_empty @bridge.queue_writes
    assert_equal "later", @bridge.queue_rows.fetch("conversation-1").first.fetch("public_id")
  end

  def test_kernel_mail_is_read_only_and_a_steering_input_can_be_canceled_but_not_edited
    open_queue
    @bridge.queue_rows["conversation-1"] = [input("kernel", "Background result", origin: "task_result"),
      input("steer", "Change direction", state: "steering", delivery_mode: "steer")]
    @runtime.consume(telegram_message(2, "/queue"))
    assert_includes reply(2), "read-only"
    assert_includes reply(2), "cancel only"
    @runtime.consume(telegram_message(3, "/queue edit 1 Changed result"))
    @runtime.consume(telegram_message(4, "/queue cancel 1"))
    @runtime.consume(telegram_message(5, "/queue edit 2 New steering"))
    assert_empty @bridge.queue_writes
    assert_includes reply(3), "read-only"
    assert_includes reply(4), "read-only"
    assert_includes reply(5), "cancel"
    @runtime.consume(telegram_message(6, "/queue cancel 2"))

    assert_equal [[:cancel, "conversation-1", "steer", "workspace-home"]], @bridge.queue_writes
    assert_equal ["kernel"], @bridge.queue_rows.fetch("conversation-1").map { |row| row.fetch("public_id") }
  end

  def test_queue_selections_are_per_user_and_topic_and_requesters_control_their_own_inputs
    2.times do |index|
      @runtime.consume(telegram_message(index + 1, "@rho_bot request #{index}", user: 2, chat: -10, topic: 4,
        entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    end
    @bridge.queue_rows["conversation-1"] = [input("input-2", "A waiting request")]
    @runtime.consume(telegram_message(3, "/queue", chat: -10, topic: 4, reply_to: 1, reply_user: 2))
    assert_includes reply(3), "A waiting request"
    @runtime.consume(telegram_message(4, "/queue cancel 1", user: 2, chat: -10, topic: 4))
    assert_includes reply(4), "Use /queue"
    @runtime.consume(telegram_message(5, "/queue", user: 2, chat: -10, topic: 4))
    @runtime.consume(telegram_message(6, "/queue cancel 1", user: 2, chat: -10, topic: 7))
    assert_includes reply(6), "Use /queue"
    assert_empty @bridge.queue_writes
    @runtime.consume(telegram_message(7, "/queue cancel 1", user: 2, chat: -10, topic: 4))
    assert_equal [[:cancel, "conversation-1", "input-2", "workspace-home"]], @bridge.queue_writes
    selections = @state.read.fetch("routes").fetch("-10:4:2").fetch("queue_selections")
    assert_equal %w[1 2], selections.keys
  end

  def test_nonowner_requester_can_cancel_their_own_pending_steering_input_after_restart
    @runtime.consume(telegram_message(1, "@rho_bot my task", user: 2, chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    @runtime.consume(telegram_message(2, "/steer my additional instruction", user: 2, chat: -10, topic: 4))
    @bridge.queue_rows["conversation-1"] = [input("input-2", "my additional instruction", state: "steering", delivery_mode: "steer")]
    @runtime = runtime
    @runtime.consume(telegram_message(3, "/queue", user: 2, chat: -10, topic: 4))
    @runtime.consume(telegram_message(4, "/queue edit 1 changed instruction", user: 2, chat: -10, topic: 4))
    assert_includes reply(4), "cannot be edited"
    assert_empty @bridge.queue_writes
    @runtime.consume(telegram_message(5, "/queue cancel 1", user: 2, chat: -10, topic: 4))

    assert_equal [[:cancel, "conversation-1", "input-2", "workspace-home"]], @bridge.queue_writes
    assert_empty @bridge.queue_rows.fetch("conversation-1")
    @runtime.consume(telegram_message(6, "/stop", user: 2, chat: -10, topic: 4))
    assert_equal ["loop-1"], @bridge.stops, "steering never replaces the original task owner"
  end

  def test_ambiguous_queue_edits_and_cancellations_are_not_repeated_after_restart
    %w[edit cancel].each_with_index do |verb, index|
      first = index * 5 + 1
      @runtime.consume(telegram_message(first, "/new"))
      conversation_id = @state.read.fetch("routes").fetch("1:0").fetch("current")
      @bridge.queue_rows[conversation_id] = [input("original-#{index}", "Waiting")]
      @runtime.consume(telegram_message(first + 1, "/queue"))
      @bridge.fail_input_control = true
      command = telegram_message(first + 2, "/queue #{verb} 1#{" corrected" if verb == "edit"}")
      assert_raises(Rho::ConnectionError) { @runtime.consume(command) }
      @bridge.queue_rows[conversation_id] = [input("later-#{index}", "Later edit")]
      count = @bridge.queue_writes.length
      @runtime = runtime
      @runtime.consume(command)
      @runtime.consume(command)

      assert_equal count, @bridge.queue_writes.length
      assert_equal "Later edit", @bridge.queue_rows.fetch(conversation_id).first.fetch("text")
      assert_includes reply(first + 2), "not repeated"
    end
  end

  def test_status_shows_current_work_and_queue_facts_without_replacing_the_numbered_selection
    open_queue
    @runtime.consume(telegram_message(2, "/queue"))
    @state.change { |doc| doc.fetch("routes").fetch("1:0")["model"] = "vendor/next" }
    @bridge.current.merge!("action" => "Waiting for an answer", "reasoning" => "private reasoning")
    @bridge.queue_rows.fetch("conversation-1").shift
    @bridge.queue_rows.fetch("conversation-1").first.merge!("state" => "blocked", "blocked_reason" => "unknown_model")
    @state.enqueue("failed-delivery", route: { "chat_id" => "1", "group" => false }, text: "Old answer", status: "uncertain")
    @state.enqueue("other-chat", route: { "chat_id" => "2", "group" => false }, text: "Elsewhere", status: "uncertain")
    @bridge.queue_reads.clear
    @runtime.consume(telegram_message(3, "/status"))

    text = reply(3)
    %w[conversation-1 vendor/next workspace-home].each { |value| assert_includes text, value }
    assert_includes text, "Waiting for an answer"
    assert_includes text, "Queued: 1"
    assert_includes text, "Blocked: 1"
    assert_includes text, "Delivery issues: 1"
    refute_includes text, "private reasoning"
    assert_equal [["conversation-1", "workspace-home"]], @bridge.queue_reads
    @runtime.consume(telegram_message(4, "/queue cancel 1"))
    assert_empty @bridge.queue_writes, "status does not silently renumber the queue selection"
  end

  def test_status_shows_the_configured_default_model_when_this_chat_has_no_override
    @runtime = runtime(default_model: "vendor/configured-default")
    open_queue
    @runtime.consume(telegram_message(2, "/status"))

    assert_includes reply(2), "Next request model: vendor/configured-default"
  end

  private

    def open_queue
      @runtime.consume(telegram_message(1, "Start current work"))
      @bridge.queue_rows["conversation-1"] = [input("first", "first request", position: 17),
        input("second", "second request", position: 42)]
    end

    def input(id, text, position: 0, origin: "person", state: "pending", delivery_mode: "queue")
      { "public_id" => id, "queue_position" => position, "text" => text, "state" => state,
        "origin" => origin, "delivery_mode" => delivery_mode, "kind" => "direct_reply" }
    end

    def reply(id) = @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")
end
