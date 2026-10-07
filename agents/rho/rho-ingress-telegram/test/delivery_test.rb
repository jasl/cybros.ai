require "support/runtime"

class TelegramDeliveryTest < Minitest::Test
  include TelegramRuntimeSupport
  def test_uncertain_formal_send_is_not_repeated_after_restart
    route = { "chat_id" => "1", "group" => false }
    @state.enqueue("answer", route: route, text: "A complete answer")
    @client.failure = Rho::IngressTelegram::Client::Unavailable.new(reason: :read, ambiguous: true)
    delivery.flush
    assert_equal "uncertain", @state.read.fetch("deliveries").fetch("answer").fetch("status")
    @state.bind(42)
    delivery.flush
    assert_equal 1, @client.calls.length
  end

  def test_crash_in_flight_remains_uncertain_and_keeps_full_body
    @state.enqueue("answer", route: { "chat_id" => "1", "group" => false }, text: "Answer")
    @state.change { |document| document.fetch("deliveries").fetch("answer")["status"] = "sending" }
    @state.bind(42)
    delivery.flush
    assert_empty @client.calls
    assert_equal "Answer", @state.read.fetch("deliveries").fetch("answer").fetch("text")
  end

  def test_explicit_format_refusal_falls_back_without_losing_chinese_or_code
    text = "你好\n\n~~~ruby\nputs 42\n~~~"
    @state.enqueue("answer", route: { "chat_id" => "1", "group" => false }, text: text)
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 400, description: "invalid entities")
    sender = delivery
    sender.flush
    sender.flush
    assert_equal %w[sendMessage sendMessage], @client.calls.map(&:first)
    assert_equal "HTML", @client.calls.first.last.fetch(:parse_mode)
    refute @client.calls.last.last.key?(:parse_mode)
    assert_equal Rho::IngressTelegram::Render.chunks(text).fetch(0).text, @client.calls.last.last.fetch(:text)
    assert_includes @client.calls.last.last.fetch(:text), "你好"
    assert_includes @client.calls.last.last.fetch(:text), "puts 42"
    assert_equal "sent", @state.read.fetch("deliveries").fetch("answer").fetch("status")
  end

  def test_plain_approval_preserves_the_exact_request_including_markdown_characters
    text = "Approve bash?\n" + JSON.pretty_generate("command" => "printf *MARKER* && echo '&amp;'", "note" => "**literal**")
    @state.enqueue("question", route: { "chat_id" => "1", "group" => false }, text: text, plain: true)

    delivery.flush

    assert_equal "sendMessage", @client.calls.last.first
    assert_equal text, @client.calls.last.last.fetch(:text)
    refute @client.calls.last.last.key?(:parse_mode)
    assert_equal "sent", @state.read.fetch("deliveries").fetch("question").fetch("status")
  end

  def test_429_blocks_final_and_control_until_floor
    monotonic = 0.0
    limits = Rho::IngressTelegram::RateLimit.new(clock: -> { monotonic })
    sender = delivery(limits: limits)
    @state.enqueue("one", route: { "chat_id" => "1", "group" => false }, text: "final")
    @state.enqueue("two", route: { "chat_id" => "2", "group" => false }, text: "control")
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 429, description: "wait", retry_after: 8)
    sender.flush
    sender.flush
    assert_equal 1, @client.calls.length
    monotonic = 8
    @now += 8
    sender.flush
    assert_equal 2, @client.calls.length
  end

  def test_429_floor_survives_restart_and_also_holds_progress
    sender = delivery
    @state.enqueue("one", route: { "chat_id" => "1", "group" => false }, text: "answer")
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 429, description: "wait", retry_after: 8)
    sender.flush
    sender = delivery
    sender.flush
    sender.progress({ "chat_id" => "2", "group" => false }, "conversation", @bridge.current)
    assert_equal 1, @client.calls.length
    @now += 8
    sender.flush
    assert_equal 2, @client.calls.length
  end

  def test_restart_does_not_announce_completion_for_an_already_completed_group_conversation
    @runtime.consume(telegram_message(1, "@rho_bot start", chat: -10,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    @runtime.tick
    @bridge.current = { "status" => "completed", "run_public_id" => "loop-1", "action" => "Waiting for work" }
    @client.calls.clear

    2.times do
      @runtime = runtime
      @runtime.tick
    end

    assert_empty @client.calls
  end

  def test_live_group_preview_finishes_by_editing_the_existing_message
    monotonic = 0.0
    sender = delivery(limits: Rho::IngressTelegram::RateLimit.new(clock: -> { monotonic }))
    route = { "chat_id" => "-10", "group" => true }
    sender.progress(route, "conversation", @bridge.current)
    message_id = @client.last_message_id
    monotonic = 60
    sender.progress(route, "conversation", @bridge.current.merge("status" => "completed", "action" => "Waiting for work"))

    assert_equal %w[sendMessage editMessageText], @client.calls.map(&:first)
    assert_equal message_id, @client.calls.last.last.fetch(:message_id)
    assert_includes @client.calls.last.last.fetch(:text), "Completed."
  end

  def test_completion_does_not_create_a_preview_that_was_throttled_while_running
    monotonic = 0.0
    limits = Rho::IngressTelegram::RateLimit.new(clock: -> { monotonic })
    route = { "chat_id" => "-10", "group" => true }
    limits.sent(chat_id: "-10", group: true)
    sender = delivery(limits: limits)
    sender.progress(route, "conversation", @bridge.current)
    monotonic = 60
    sender.progress(route, "conversation", @bridge.current.merge("status" => "completed"))

    assert_empty @client.calls
  end

  def test_finishing_a_private_draft_never_falls_back_to_a_new_formal_completion_message
    sender = delivery
    route = { "chat_id" => "1", "group" => false }
    sender.progress(route, "conversation", @bridge.current)
    @now += 60
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 400, description: "draft unavailable")

    2.times { sender.progress(route, "conversation", @bridge.current.merge("status" => "completed")) }

    assert_equal ["sendMessageDraft"], @client.calls.map(&:first)
    assert @client.failure, "a terminal draft needs no Telegram request"
  end

  def test_a_private_fallback_preview_finishes_by_editing_its_existing_message
    monotonic = 0.0
    sender = delivery(limits: Rho::IngressTelegram::RateLimit.new(clock: -> { monotonic }))
    route = { "chat_id" => "1", "group" => false }
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 400, description: "draft unavailable")
    sender.progress(route, "conversation", @bridge.current)
    sender.progress(route, "conversation", @bridge.current)
    message_id = @client.last_message_id
    monotonic = 60

    sender.progress(route, "conversation", @bridge.current.merge("status" => "completed", "action" => "Waiting for work"))

    assert_equal %w[sendMessageDraft sendMessage editMessageText], @client.calls.map(&:first)
    assert_equal message_id, @client.calls.last.last.fetch(:message_id)
    assert_equal "Completed.", @client.calls.last.last.fetch(:text)
  end

  def test_a_new_loop_retires_the_previous_group_preview_without_waiting_for_its_terminal_snapshot
    monotonic = 0.0
    sender = delivery(limits: Rho::IngressTelegram::RateLimit.new(clock: -> { monotonic }))
    route = { "chat_id" => "-10", "group" => true }
    sender.progress(route, "conversation", @bridge.current)
    message_id = @client.last_message_id
    monotonic = 60
    sender.progress(route, "conversation", @bridge.current.merge("run_public_id" => "replacement"))

    assert_equal %w[sendMessage editMessageText], @client.calls.map(&:first)
    assert_equal message_id, @client.calls.last.last.fetch(:message_id)
    assert_includes @client.calls.last.last.fetch(:text), "no longer current"
    monotonic = 120
    sender.progress(route, "conversation", @bridge.current.merge("run_public_id" => "replacement"))
    assert_equal "sendMessage", @client.calls.last.first
    assert_includes @client.calls.last.last.fetch(:text), "Working"
  end

  private

    def delivery(limits: Rho::IngressTelegram::RateLimit.new)
      Rho::IngressTelegram::Delivery.new(client: @client, state: @state, limits: limits, clock: -> { @now })
    end
end
