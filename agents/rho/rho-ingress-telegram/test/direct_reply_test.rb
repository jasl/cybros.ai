require "support/runtime"

class TelegramDirectReplyTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_normal_chat_delivers_the_answer_without_a_task_receipt
    @runtime.consume(telegram_message(1, "你好"))
    @bridge.current.merge!("status" => "completed")
    @bridge.turn_rows["conversation-1"] = [turn(0, "你好！有什么可以帮你？")]
    @runtime.tick

    assert_equal ["你好！有什么可以帮你？"], formal_messages.map { |message| message.fetch(:text) }
    assert_equal({ message_id: 1, allow_sending_without_reply: true }, formal_messages.first.fetch(:reply_parameters))
    refute @state.read.fetch("deliveries").key?("control:1")
    assert_equal "input-1", @state.read.fetch("requests").fetch("telegram:42:1:input").fetch("input_id")
  end

  def test_background_work_keeps_the_assistants_launch_acknowledgement_and_later_result
    @runtime.consume(telegram_message(1, "Prepare the report in the background"))
    @bridge.current.merge!("status" => "completed")
    @bridge.turn_rows["conversation-1"] = [turn(0, "The report is running in the background. I will send it here when ready.")]
    @runtime.tick

    assert_equal ["The report is running in the background. I will send it here when ready."], formal_messages.map { |message| message.fetch(:text) }
    @bridge.event_rows["conversation-1"] = [
      { "type" => "input_accepted", "cursor" => "1", "sequence" => 1,
        "payload" => { "input_public_id" => "background-input", "origin" => "task_result", "run_public_id" => "loop-1" } },
      { "type" => "input_materialized", "cursor" => "2", "sequence" => 2,
        "payload" => { "input_public_id" => "background-input", "turn_public_id" => "turn-1" } },
      { "type" => "turn_status", "cursor" => "3", "sequence" => 3,
        "payload" => { "turn_public_id" => "turn-1", "run_public_id" => "background-loop" } },
    ]
    @bridge.turn_rows["conversation-1"] << turn(1, "The completed report.")
    @bridge.current.merge!("sequence" => 3, "run_public_id" => "background-loop")
    @now += 1
    @runtime.tick

    assert_equal ["The report is running in the background. I will send it here when ready.", "The completed report."],
      formal_messages.map { |message| message.fetch(:text) }
    assert formal_messages.all? { |message| message.fetch(:reply_parameters).fetch(:message_id) == 1 }
  end

  def test_a_private_draft_does_not_reappear_after_the_next_tick_delivers_the_final_answer
    @runtime.consume(telegram_message(1, "你好"))
    @runtime.tick
    assert_equal ["sendMessageDraft"], @client.calls.map(&:first)

    @bridge.current.merge!("status" => "completed", "sequence" => 2, "action" => "Waiting for work")
    @bridge.turn_rows["conversation-1"] = [turn(0, "你好！")]
    @now += 1
    @runtime.tick
    assert_equal ["你好！"], formal_messages.map { |message| message.fetch(:text) }

    5.times do
      @now += 1
      @runtime.tick
    end

    assert_equal %w[sendMessageDraft sendMessage], @client.calls.map(&:first)
    refute @client.calls.any? { |_method, params| params[:text].to_s.include?("Completed.") }
  end

  def test_lost_acceptance_response_recovers_without_a_receipt_or_duplicate_answer
    @bridge.fail_input = true
    update = telegram_message(1, "Hello")
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    @runtime = runtime
    @runtime.consume(update)
    @runtime.consume(update)
    @bridge.current.merge!("status" => "completed")
    @bridge.turn_rows["conversation-1"] = [turn(0, "Hello!")]
    @runtime.tick
    @runtime = runtime
    @runtime.tick

    assert_equal 1, @bridge.inputs.length
    assert_equal ["Hello!"], formal_messages.map { |message| message.fetch(:text) }
  end

  private

    def formal_messages = @client.calls.filter_map { |method, params| params if method == "sendMessage" }
end
