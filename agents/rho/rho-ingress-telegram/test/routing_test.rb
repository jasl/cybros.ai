require "support/runtime"

class TelegramRoutingTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_ordinary_group_reply_thread_keeps_the_requesters_conversation
    @runtime.consume(telegram_message(1, "@rho_bot start", chat: -10,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    reply = telegram_message(2, "Continue this conversation", chat: -10)
    reply.fetch("message").merge!("message_thread_id" => 8,
      "reply_to_message" => { "message_id" => 1, "from" => { "id" => 1 } })

    @runtime.consume(reply)

    assert_equal 1, @bridge.opened.length
    assert_equal 2, @bridge.inputs.length
    assert_equal ["conversation-1"], @bridge.inputs.values.map { |input| input.fetch(:conversation_id) }.uniq
    assert_equal ["-10:0:1"], @state.read.fetch("routes").keys
    assert_nil @state.read.fetch("routes").fetch("-10:0:1")["topic_id"]
    refute @state.read.fetch("deliveries").key?("control:2")
  end
end
