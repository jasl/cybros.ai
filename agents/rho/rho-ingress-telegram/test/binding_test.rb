require "support/runtime"

class TelegramBindingTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_binding_is_a_projection_of_the_current_chat_and_topic_after_restart
    @runtime.consume(telegram_message(1, "hello"))
    @runtime.consume(telegram_message(2, "@rho_bot hello", chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))

    assert_equal({ "channel" => "telegram", "label" => "Telegram · Chat 1", "chat_id" => "1", "topic_id" => nil },
      state.binding("conversation-1"))
    assert_equal({ "channel" => "telegram", "label" => "Telegram · Chat -10 · Topic 4 · User 1", "chat_id" => "-10", "topic_id" => 4 },
      state.binding("conversation-2"))
    assert_nil state.binding("unrelated")
  end

  def test_new_releases_the_previous_conversation_without_losing_its_background_tracker
    @runtime.consume(telegram_message(1, "hello"))
    @runtime.consume(telegram_message(2, "/new"))

    assert_nil @state.binding("conversation-1")
    assert_equal "1", @state.binding("conversation-2").fetch("chat_id")
    assert @state.read.fetch("routes").fetch("1:0").fetch("conversations").key?("conversation-1")
  end

  def test_workspace_switch_releases_only_that_topics_current_conversation
    @runtime.consume(telegram_message(1, "@rho_bot hello", chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    @runtime.consume(telegram_message(2, "@rho_bot hello", chat: -10, topic: 5,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    @runtime.consume(telegram_message(3, "/workspace use workspace-project", chat: -10, topic: 4))

    assert_nil @state.binding("conversation-1")
    assert_equal 5, @state.binding("conversation-2").fetch("topic_id")
    assert_equal 4, @state.binding("conversation-3").fetch("topic_id")
    assert @state.read.fetch("routes").fetch("-10:4:1").fetch("conversations").key?("conversation-1")
  end
end
