require "minitest/autorun"
require "rho/ingress-telegram"
require_relative "../support/telegram_client"

class TelegramClientHarnessTest < Minitest::Test
  def test_typing_records_the_chat_action_without_creating_a_message
    client = E2E::TelegramClient.new
    action = { chat_id: "-10", message_thread_id: 7, action: "typing" }

    assert_equal true, client.call("sendChatAction", action)
    assert_equal [["sendChatAction", action]], client.calls
    assert_empty client.messages
    assert_empty client.formal(-10)

    message = { chat_id: "-10", message_thread_id: 7, text: "Finished", parse_mode: "HTML" }
    response = client.call("sendMessage", message)
    assert_equal message, client.messages.fetch(response.fetch("message_id"))
    assert_equal [["sendMessage", message]], client.formal(-10)
  end
end
