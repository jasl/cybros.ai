require "support/runtime"

class TelegramBindingTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_binding_projects_the_original_fixed_target_after_restart
    receive(group_message(1, "@rho_bot hello"))
    receive(group_message(2, "@rho_bot another member", user: 2))
    state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))

    assert_equal({ "channel" => "telegram", "label" => "Telegram · Chat -10 · Topic 4", "chat_id" => "-10", "topic_id" => 4,
      "connection_public_id" => CONNECTION }, state.binding("conversation-1"))
    assert_nil state.binding("unrelated")
    assert_equal 1, @bridge.opened.size, "the fixed group target shares one Bot conversation"
  end

  def test_new_preserves_old_binding_and_background_tracker
    receive(group_message(1, "@rho_bot hello"))
    receive(group_message(2, "/new"))

    assert_equal "conversation-2", @bridge.bot_detail.dig("current", "public_id")
    assert_equal @state.binding("conversation-1"), @state.binding("conversation-2")
    assert_equal "-10", @state.binding("conversation-1").fetch("chat_id")
    assert @state.read.fetch("routes").fetch("#{CONNECTION}:-10:4").fetch("conversations").key?("conversation-1")
  end

  def test_home_switch_preserves_each_conversations_workspace_and_original_target
    receive(group_message(1, "@rho_bot hello"))
    receive(group_message(2, "/workspace use workspace-project"))
    routes = @state.read.fetch("routes")
    conversations = routes.fetch("#{CONNECTION}:-10:4").fetch("conversations")

    assert_equal "workspace-home", conversations.fetch("conversation-1").fetch("workspace_public_id")
    assert_equal "workspace-project", conversations.fetch("conversation-2").fetch("workspace_public_id")
    assert_equal "conversation-2", @bridge.bot_detail.dig("current", "public_id")
    assert_equal @state.binding("conversation-1"), @state.binding("conversation-2")
    refute routes.values.any? { |route| route.key?("current") || route.key?("owner_id") }
  end

  private

    def group_message(id, text, user: 1)
      telegram_message(id, text, user: user, chat: -10, topic: 4,
        entities: (text.start_with?("@rho_bot") ? [{ "type" => "mention", "offset" => 0, "length" => 8 }] : []))
    end
end
