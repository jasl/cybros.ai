require "support/runtime"

class TelegramReminderWorkflowTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_one_time_reminder_is_a_queued_request_with_speaker_scope_and_a_receipt
    @runtime.consume(telegram_message(1, "/remind in 20m Submit the report"))

    input = @bridge.inputs.fetch("telegram:42:1:input")
    assert_equal "1970-01-01T00:36:40Z", input.fetch(:deliver_at)
    assert_equal "queue", input.fetch(:mode)
    assert_equal "speaker-1", input.fetch(:speaker)
    assert_equal "workspace-home", input.fetch(:workspace_public_id)
    assert_equal "Please remind me now: Submit the report", input.fetch(:text)
    refute input.key?(:tool_names)
    request = @state.read.fetch("requests").fetch("telegram:42:1:input")
    assert_equal "input-1", request.fetch("input_id")
    assert_nil request["run_id"], "the future input does not pretend to be running"
    assert_includes reply(1), input.fetch(:deliver_at)
    assert_includes reply(1), "may arrive later"
    assert_includes reply(1), "/queue"
  end

  def test_relative_reminder_recovers_lost_acceptance_after_the_fresh_input_window_and_delivers_once
    submitted = []
    original = @bridge.method(:submit)
    @bridge.define_singleton_method(:submit) do |id, **request|
      submitted << request.merge(conversation_id: id)
      original.call(id, **request)
    end
    @bridge.fail_input = true
    update = telegram_message(1, "/remind in 20m Check the answer")
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    assert_equal "1970-01-01T00:36:40Z", @state.read.fetch("pending_update").fetch("deliver_at")
    @bridge.default_workspace = @bridge.workspace_rows.last
    @now += 1_300
    @runtime = runtime
    @runtime.consume(update)
    @runtime.consume(update)

    assert_equal 2, submitted.length
    assert_equal submitted.first, submitted.last
    assert_equal 1, @bridge.inputs.length
    assert_equal "workspace-home", submitted.last.fetch(:workspace_public_id)
    assert_equal "input-1", @state.read.fetch("requests").fetch("telegram:42:1:input").fetch("input_id")
    assert_nil @state.read["pending_update"]

    @bridge.event_rows["conversation-1"] = [{ "type" => "input_materialized", "cursor" => "event-1", "sequence" => 1,
      "payload" => { "input_public_id" => "input-1", "turn_public_id" => "turn-0" } }]
    @bridge.turn_rows["conversation-1"] = [turn(0, "Reminder: check the answer.")]
    @bridge.current = { "status" => "completed" }
    4.times do
      @runtime.tick
      @now += 5
    end

    messages = @client.calls.select { |name, fields| name == "sendMessage" && fields[:text].to_s.include?("Reminder: check") }
    assert_equal 1, messages.length
    assert_equal "1", messages.first.last.fetch(:chat_id)
  end

  def test_a_reminder_first_received_after_the_fresh_input_window_is_consumed_without_admission
    stage = @state.method(:stage)
    @state.define_singleton_method(:stage) do |update|
      stage.call(update)
      raise Rho::ConnectionError, "response lost after staging"
    end
    @now += 601
    @runtime.consume(telegram_message(1, "/remind in 20m Too old"))

    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_empty @state.read.fetch("requests")
    assert_nil @state.read["pending_update"]
    assert_equal 2, @state.read.fetch("offset")
  end

  def test_lost_acceptance_outside_the_receipt_window_is_not_resubmitted_or_left_blocking_delivery
    @bridge.fail_input = true
    update = telegram_message(1, "/remind in 2d Check the answer")
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    @bridge.define_singleton_method(:submit) { |*| raise "expired input must not be resubmitted" }
    @now += 24 * 60 * 60
    @runtime = runtime
    @runtime.consume(update)

    assert_equal 1, @bridge.inputs.length
    assert @state.read.fetch("requests").fetch("telegram:42:1:input").fetch("retired")
    assert_nil @state.read["pending_update"]
    assert_includes reply(1), "not resubmitted"
    assert_includes reply(1), "/queue"
    assert_includes reply(1), "/history"

    @bridge.turn_rows["conversation-1"] = [turn(0, "Later background answer")]
    @bridge.current = { "status" => "completed" }
    4.times do
      @runtime.tick
      @now += 5
    end

    messages = @client.calls.select { |name, fields| name == "sendMessage" && fields[:text].to_s.include?("Later background answer") }
    assert_equal 1, messages.length
  end

  def test_absolute_reminder_requires_a_timezone_and_invalid_or_media_commands_open_nothing
    @runtime.consume(telegram_message(1, "/remind at 2026-10-03T09:00:00 Need a zone"))
    @runtime.consume(telegram_message(2, "/remind in nonsense Bad duration"))
    @runtime.consume(telegram_message(3, "/remind daily 09:00 Unsupported recurrence"))
    media = telegram_message(4, "/remind in 20m A picture")
    media.fetch("message")["photo"] = [{ "file_id" => "photo", "file_size" => 10 }]
    @runtime.consume(media)

    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_includes reply(1), "offset"
    assert_includes reply(2), "20m"
    assert_includes reply(3), "Use /remind"
    assert_includes reply(4), "text only"
    @runtime.consume(telegram_message(5, "/remind at 2026-10-03T09:00:00+08:00 Review the report"))
    assert_equal "2026-10-03T01:00:00Z", @bridge.inputs.values.last.fetch(:deliver_at)
  end

  def test_group_requester_keeps_the_isolated_profile_and_can_reschedule_only_their_input
    @bridge.declared_tools[true] = %w[read bash write]
    @runtime.consume(telegram_message(1, "/remind in 20m My report", user: 2, chat: -10, topic: 4))
    input = @bridge.inputs.fetch("telegram:42:1:input")
    assert_equal true, input.fetch(:isolated)
    assert_equal ["read"], input.fetch(:tool_names)
    assert_equal "speaker-2", input.fetch(:speaker)
    @bridge.queue_rows["conversation-1"] = [queued_input("input-1", input), queued_input("other", input)]
    @runtime.consume(telegram_message(2, "/queue", user: 2, chat: -10, topic: 4))
    @runtime.consume(telegram_message(3, "/queue reschedule 1 in 1h", user: 2, chat: -10, topic: 7))
    assert_empty @bridge.queue_writes
    @runtime.consume(telegram_message(4, "/queue reschedule 2 in 1h", user: 2, chat: -10, topic: 4))
    assert_includes reply(4), "request's sender"
    @runtime.consume(telegram_message(5, "/queue reschedule 1 in 1h", user: 2, chat: -10, topic: 4))

    assert_equal [[:reschedule, "conversation-1", "input-1", { "deliver_at" => "1970-01-01T01:16:40Z" }, "workspace-home"]], @bridge.queue_writes
    assert_equal ["read"], @bridge.queue_rows.fetch("conversation-1").first.fetch("tool_names")
    @bridge.queue_rows.fetch("conversation-1").first["tool_names"] = ["write"]
    @runtime.consume(telegram_message(6, "/queue reschedule 1 now", user: 2, chat: -10, topic: 4))
    assert_equal 1, @bridge.queue_writes.length
    assert_includes reply(6), "read-only"
  end

  def test_reschedule_keeps_content_and_attachments_and_now_is_due_at_the_next_boundary
    @runtime.consume(telegram_message(1, "/remind in 20m My report"))
    input = @bridge.inputs.values.first
    @bridge.queue_rows["conversation-1"] = [queued_input("input-1", input).merge("attachments" => [{ "upload_public_id" => "picture" }])]
    @runtime.consume(telegram_message(2, "/queue"))
    @runtime.consume(telegram_message(3, "/queue reschedule 1 at 2026-10-03T09:00:00+08:00"))
    row = @bridge.queue_rows.fetch("conversation-1").first
    assert_equal "2026-10-03T01:00:00Z", row.fetch("deliver_at")
    assert_equal input.fetch(:text), row.fetch("text")
    assert_equal [{ "upload_public_id" => "picture" }], row.fetch("attachments")
    @runtime.consume(telegram_message(4, "/queue reschedule 1 now"))
    assert_equal "1970-01-01T00:16:40Z", row.fetch("deliver_at")
    assert_includes reply(4), "next request"
    @runtime.consume(telegram_message(5, "/queue cancel 1"))
    assert_empty @bridge.queue_rows.fetch("conversation-1")
  end

  def test_lost_reschedule_response_is_not_reapplied_after_restart
    @runtime.consume(telegram_message(1, "/remind in 20m My report"))
    @bridge.queue_rows["conversation-1"] = [queued_input("input-1", @bridge.inputs.values.first)]
    @runtime.consume(telegram_message(2, "/queue"))
    @bridge.fail_input_control = true
    update = telegram_message(3, "/queue reschedule 1 in 1h")
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    @now += 60
    @runtime = runtime
    @runtime.consume(update)

    assert_equal 1, @bridge.queue_writes.length
    assert_includes reply(3), "not repeated"
  end

  def test_due_reminder_uses_the_existing_reply_delivery_after_a_new_conversation_and_restart
    @runtime.consume(telegram_message(1, "/remind in 20m My report"))
    @runtime.consume(telegram_message(2, "/new"))
    @bridge.event_rows["conversation-1"] = [{ "type" => "input_materialized", "cursor" => "event-1", "sequence" => 1,
      "payload" => { "input_public_id" => "input-1", "turn_public_id" => "turn-0" } }]
    @bridge.turn_rows["conversation-1"] = [turn(0, "Reminder: submit your report.")]
    @bridge.current = { "status" => "completed" }
    @runtime = runtime
    4.times do
      @runtime.tick
      @now += 5
    end

    messages = @client.calls.select { |name, fields| name == "sendMessage" && fields[:text].to_s.include?("Reminder: submit") }
    assert_equal 1, messages.length
    assert_equal "1", messages.first.last.fetch(:chat_id)
    assert_equal "conversation-2", @state.read.fetch("routes").fetch("1:0").fetch("current")
  end

  private

    def queued_input(id, input)
      { "public_id" => id, "state" => "pending", "delivery_mode" => "queue", "origin" => "person",
        "text" => input.fetch(:text), "tool_names" => input[:tool_names], "deliver_at" => input.fetch(:deliver_at) }
    end

    def reply(id) = @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")
end
