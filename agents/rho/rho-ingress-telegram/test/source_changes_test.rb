require "support/runtime"

class TelegramSourceChangesTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_missing_source_retires_tracking_and_unsent_content_without_opening_another_conversation
    queue_answer
    @bridge.read_failure = refused(404)
    @runtime.tick

    route = @state.read.fetch("routes").fetch("1:0")
    assert_equal "conversation-1", route.fetch("current")
    assert_empty route.fetch("conversations")
    refute @state.read.fetch("deliveries").key?("turn:conversation-1:turn-0:conversation-1-variant-0")
    refute @client.calls.any? { |_method, parameters| parameters[:text] == "Old answer" }
    assert_equal 1, @bridge.opened.length
    assert @client.calls.any? { |_method, parameters| parameters[:text].to_s.include?("/new") }
  end

  def test_forbidden_source_retires_pending_question_and_its_controls
    queue_answer
    @state.change do |document|
      document.fetch("questions")["question"] = { "conversation_id" => "conversation-1", "route_key" => "1:0" }
      document.fetch("deliveries")["question:question"] = {
        "status" => "pending", "chat_id" => "1", "group" => false, "text" => "Private question", "question_id" => "question",
      }
    end
    @bridge.read_failure = refused(403)
    @runtime.tick

    assert_empty @state.read.fetch("questions")
    refute @state.read.fetch("deliveries").key?("question:question")
    refute @client.calls.any? { |_method, parameters| parameters[:text] == "Private question" }
  end

  def test_a_restored_missing_source_requires_explicit_new_before_accepting_more_input
    assert_explicit_recovery(404, "/new")
  end

  def test_a_restored_forbidden_source_can_recover_through_workspace_selection
    assert_explicit_recovery(403, "/workspace use workspace-project")
  end

  def test_stop_reply_to_a_retired_source_is_consumed_without_stopping_the_new_task
    assert_retired_task_control("/stop")
  end

  def test_steer_reply_to_a_retired_source_is_consumed_without_steering_the_new_task
    assert_retired_task_control("/steer keep the original goal")
  end

  def test_temporary_source_failure_preserves_tracking_and_defers_a_queued_answer
    queue_answer
    @bridge.read_failure = refused(503)
    @runtime.define_singleton_method(:sleep) { |_seconds| }
    @runtime.tick

    assert @state.read.fetch("routes").fetch("1:0").fetch("conversations").key?("conversation-1")
    assert_equal "pending", @state.read.fetch("deliveries").fetch("turn:conversation-1:turn-0:conversation-1-variant-0").fetch("status")
    assert_empty @client.calls
    @bridge.read_failure = nil
    @runtime.tick
    assert @client.calls.any? { |_method, parameters| parameters[:text] == "Old answer" }
  end

  def test_swiping_the_source_discards_a_delayed_answer_instead_of_sending_old_text
    queue_answer
    @bridge.turn_rows["conversation-1"] = [turn(0, "Replacement").merge("variant_public_id" => "replacement")]
    @runtime.tick

    refute @state.read.fetch("deliveries").key?("turn:conversation-1:turn-0:conversation-1-variant-0")
    refute @client.calls.any? { |_method, parameters| parameters[:text] == "Old answer" }
  end

  def test_a_question_waits_for_a_successful_pending_refresh_and_missing_questions_never_send
    @runtime.consume(telegram_message(1, "start"))
    @state.change { |document| document["retry_at"] = @now + 1 }
    @bridge.pending_rows = [{ "workspace_public_id" => "workspace-home", "run_public_id" => "loop-1", "task_key" => "ask",
      "kind" => "ask", "question" => "Choose one" }]
    @runtime.tick
    question_id = @state.read.fetch("questions").keys.fetch(0)
    @now += 1
    @runtime = runtime
    @runtime.define_singleton_method(:sleep) { |_seconds| }
    @bridge.define_singleton_method(:pending) { |_id, **| raise Rho::ConnectionError, "temporary failure" }
    @client.calls.clear
    @runtime.tick
    assert_empty @client.calls
    assert_equal "pending", @state.read.fetch("deliveries").fetch("question:#{question_id}").fetch("status")

    @state.change { |document| document.fetch("questions").clear }
    @runtime.tick
    refute @client.calls.any? { |method, _parameters| method == "sendMessage" },
      "local progress may continue between reconciliations, but the removed question must never send"
  end

  def test_archive_does_not_hide_readable_formal_history
    queue_answer
    @bridge.current = { "status" => "completed", "archived_at" => "2026-09-30", "run_public_id" => "loop-1" }
    @runtime.tick

    assert @client.calls.any? { |_method, parameters| parameters[:text] == "Old answer" }
    assert @state.read.fetch("routes").fetch("1:0").fetch("conversations").key?("conversation-1")
  end

  def test_reply_to_a_retired_bot_question_never_becomes_a_new_model_input
    @runtime.consume(telegram_message(1, "start"))
    reply = telegram_message(2, "The old answer")
    reply.fetch("message")["reply_to_message"] = {
      "message_id" => 500, "from" => { "id" => 42, "is_bot" => true },
      "text" => "Question (0123456789ab)\nWhich option?\nReply to this message, or use /answer 0123456789ab your answer.",
    }
    @runtime.consume(reply)

    assert_equal 1, @bridge.inputs.length
    assert_includes @state.read.fetch("deliveries").fetch("control:2").fetch("text"), "no longer available"
    assert_empty @bridge.decisions
  end

  def test_another_bots_question_format_does_not_intercept_a_normal_private_message
    @runtime.consume(telegram_message(1, "start"))
    reply = telegram_message(2, "An ordinary request")
    reply.fetch("message")["reply_to_message"] = {
      "message_id" => 500, "from" => { "id" => 99, "is_bot" => true }, "text" => "Question (0123456789ab)\nSomething?",
    }
    @runtime.consume(reply)
    assert_equal 2, @bridge.inputs.length
  end

  def test_swipe_after_429_is_checked_again_before_retrying_the_formal_message
    queue_answer
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 429, description: "wait", retry_after: 10)
    @runtime.tick
    assert_equal "pending", @state.read.fetch("deliveries").fetch("turn:conversation-1:turn-0:conversation-1-variant-0").fetch("status")
    @runtime = runtime
    @now += 10
    @bridge.turn_rows["conversation-1"] = [turn(0, "Replacement").merge("variant_public_id" => "replacement")]
    @runtime.tick

    assert_equal 1, @client.calls.count { |_method, parameters| parameters[:text] == "Old answer" }, "the explicitly refused attempt is never repeated"
    refute @state.read.fetch("deliveries").key?("turn:conversation-1:turn-0:conversation-1-variant-0")
  end

  def test_a_read_loss_at_send_preflight_does_not_publish_the_earlier_progress_snapshot
    queue_answer
    @bridge.define_singleton_method(:turn_source) do |_id, position:, **|
      raise Rho::Core::Refused.new("Not found", code: "not_found", status: 404)
    end
    @runtime.tick

    assert_empty @client.calls
    assert_empty @state.read.fetch("routes").fetch("1:0").fetch("conversations")
    assert @state.read.fetch("deliveries").key?("unavailable:conversation-1")
  end

  def test_send_preflight_retirement_also_discards_a_blocked_notice_in_the_flush_snapshot
    queue_answer
    @state.enqueue("blocked:conversation-1:input-1", route: { "chat_id" => "1", "group" => false },
      text: "A queued request needs attention. Use the rho CLI to resolve it.", plain: true, conversation_id: "conversation-1")
    @bridge.define_singleton_method(:turn_source) do |_id, position:, **|
      raise Rho::Core::Refused.new("Not found", code: "not_found", status: 404)
    end

    @runtime.tick

    assert_empty @client.calls
    refute @state.read.fetch("deliveries").key?("blocked:conversation-1:input-1")
    assert_empty @state.read.fetch("routes").fetch("1:0").fetch("conversations")
    assert @state.read.fetch("deliveries").key?("unavailable:conversation-1")
  end

  private

    def assert_retired_task_control(command)
      queue_answer
      @bridge.read_failure = refused(404)
      @runtime.tick
      @bridge.read_failure = nil
      @runtime.consume(telegram_message(2, "/new"))
      @runtime.consume(telegram_message(3, "New task"))
      @runtime = runtime
      @runtime.consume(telegram_message(4, command, reply_to: 1, reply_user: 1))

      document = @state.read
      assert_includes document.fetch("deliveries").fetch("control:4").fetch("text"), "no longer followed"
      assert_nil document["pending_update"]
      assert_equal 5, document.fetch("offset")
      assert_equal "conversation-2", document.fetch("routes").fetch("1:0").fetch("current")
      assert_equal 2, @bridge.inputs.length
      assert_equal 2, @bridge.opened.length
      assert_empty @bridge.stops

      @runtime.consume(telegram_message(5, "Continue the new task"))
      assert_nil @state.read["pending_update"]
      assert_equal 6, @state.read.fetch("offset")
      assert_equal 3, @bridge.inputs.length
      assert_equal "conversation-2", @bridge.inputs.fetch("telegram:42:5:input").fetch(:conversation_id)
    end

    def assert_explicit_recovery(status, command)
      queue_answer
      @bridge.read_failure = refused(status)
      @runtime.tick
      @bridge.read_failure = nil
      @runtime = runtime
      @runtime.consume(telegram_message(2, "The source is readable again"))

      assert_equal 1, @bridge.inputs.length, "a retired conversation must not accept an unfollowed request"
      assert_equal 1, @bridge.opened.length
      assert_nil @state.read["pending_update"]
      assert_equal 3, @state.read.fetch("offset")
      refusal = @state.read.fetch("deliveries").fetch("control:2").fetch("text")
      assert_includes refusal, "/new"
      assert_includes refusal, "/workspace"

      @runtime.consume(telegram_message(3, command))
      @runtime.consume(telegram_message(4, "Continue in the new conversation"))
      route = @state.read.fetch("routes").fetch("1:0")
      assert_equal "conversation-2", route.fetch("current")
      assert route.fetch("conversations").key?("conversation-2")
      assert_equal 2, @bridge.inputs.length
      assert_equal "conversation-2", @bridge.inputs.fetch("telegram:42:4:input").fetch(:conversation_id)
    end

    def queue_answer
      @runtime.consume(telegram_message(1, "start"))
      @state.change do |document|
        document.fetch("deliveries").clear
        document.fetch("routes").fetch("1:0").fetch("conversations").fetch("conversation-1")["position"] = 0
      end
      @bridge.turn_rows["conversation-1"] = [turn(0, "Old answer")]
      @state.enqueue("turn:conversation-1:turn-0:conversation-1-variant-0", route: { "chat_id" => "1", "group" => false },
        text: "Old answer", conversation_id: "conversation-1", turn_id: "turn-0", variant_public_id: "conversation-1-variant-0", position: 0)
    end

    def refused(status)
      Rho::Core::Refused.new("Source unavailable", code: "not_found", status: status)
    end
end
