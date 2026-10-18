require "support/runtime"

class TelegramGatewayCommandsTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_platform_help_and_menu_advertise_the_same_gateway_controls
    receive(telegram_message(1, "/help"))
    text = @state.read.fetch("deliveries").fetch("control:telegram:#{BOT}:#{CONNECTION}:42:1:reply").fetch("text")
    menu = Rho::IngressTelegram::Commands::MENU

    assert_includes text, "In groups, mention me or reply to your task's receipt or answer."
    assert_includes text, "reply to a question message"
    assert_includes menu.map { |entry| entry.fetch(:command) }, "steer"
    refute_includes menu.map { |entry| entry.fetch(:command) }, "btw"
    refute_includes menu.map { |entry| entry.fetch(:command) }, "side"
    refute_includes text, "/btw"
    refute_includes text, "/side"
    menu.each { |entry| assert_includes text, "/#{entry.fetch(:command)}" }
    assert_empty @bridge.inputs
  end

  def test_empty_busy_commands_do_not_create_a_conversation_or_register_a_speaker
    receive(telegram_message(1, "/steer@rho_bot \n\t"))
    assert_includes @state.read.fetch("deliveries").fetch("control:telegram:#{BOT}:#{CONNECTION}:42:1:reply").fetch("text"), "/steer <text>"
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_empty @bridge.speakers
  end

  def test_code_mode_explains_bot_policy_without_opening_or_changing_a_conversation
    ["/codemode", "/codemode on", "/codemode off"].each_with_index do |command, index|
      receive(telegram_message(index + 1, command, user: 2, chat: -10, topic: 4))
      assert_includes reply(index + 1), "Bots do not use Code Mode."
    end
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_empty @bridge.stops
  end

  def test_group_members_can_start_a_request_and_steer_their_own_task
    receive(telegram_message(1, "@rho_bot explain this", user: 2, chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    receive(telegram_message(2, "/steer change the explanation", user: 2, chat: -10, topic: 4, reply_to: 1, reply_user: 2))

    assert_equal ["conversation-1", "conversation-1"], @bridge.inputs.values.map { |input| input.fetch(:conversation_id) }
    assert_equal "loop-1", @bridge.inputs.values.last.fetch(:expected_steering_run_public_id)
    assert_equal "steer", @bridge.inputs.values.last.fetch(:mode)
    assert_equal ["#{CONNECTION}:-10:4"], @state.read.fetch("routes").keys
    assert_empty @bridge.stops
  end

  def test_group_members_read_the_same_bot_settings_and_topic_observation_without_mutation
    allow_another_member_and_group
    receive(telegram_message(1, "/new", chat: -10, topic: 4))
    receive(telegram_message(2, "/workspace use Project", chat: -10, topic: 4))
    @state.change do |document|
      document.fetch("routes").fetch("#{CONNECTION}:-10:4").merge!("model" => "vendor/shared", "voice" => "all")
    end
    @client.admin = true
    receive(telegram_message(3, "/observe on", chat: -10, topic: 4))
    routes = @state.read.fetch("routes")
    speakers = @bridge.speakers.dup

    receive(telegram_message(4, "/settings", user: 2, chat: -10, topic: 4))
    receive(telegram_message(5, "/settings", user: 3, chat: -10, topic: 4))
    [4, 5].each do |id|
      assert_includes reply(id), "Workspace: Project (workspace-project)"
      assert_includes reply(id), "Model: vendor/shared"
      assert_includes reply(id), "Voice: all"
      assert_includes reply(id), "Group behavior:"
      assert_includes reply(id), "Requests: explicit mentions or replies to the bot or a known task."
      assert_includes reply(id), "Observe: on"
      assert_includes reply(id), "Shared scope: this topic (4) in group -10."
      assert_includes reply(id), "Only the bot owner can change this setting."
      assert_includes reply(id), "Background context does not start the agent."
      assert_includes reply(id), "Shared Bot conversation settings in this topic (4) in group -10:"
    end
    assert_equal routes, @state.read.fetch("routes")
    assert_equal ["#{CONNECTION}:-10:4"], @state.read.fetch("rooms").keys
    assert_equal 2, @bridge.opened.length
    assert_empty @bridge.inputs
    assert_equal speakers, @bridge.speakers
    assert_empty @bridge.stops
  end

  def test_settings_distinguish_a_group_without_topics_from_a_private_chat
    receive(telegram_message(1, "/settings", user: 2, chat: -10))
    receive(telegram_message(2, "/settings", user: 2))

    assert_includes reply(1), "Shared scope: this group (-10)."
    assert_includes reply(1), "Shared Bot conversation settings in this group (-10):"
    assert_includes reply(2), "Your conversation settings in this private chat:"
    assert_includes reply(2), "Workspace: Home (workspace-home)"
    refute_includes reply(2), "Group behavior:"
    refute_includes reply(2), "Observe:"
    assert_empty @state.read.fetch("routes")
    assert_empty @state.read.fetch("rooms")
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
  end

  def test_allowed_members_can_read_observation_but_only_the_owner_changes_the_current_topic
    allow_another_member_and_group
    @client.admin = true
    receive(telegram_message(1, "/observe", user: 2, chat: -10, topic: 4))
    receive(telegram_message(2, "/observe status", user: 3, chat: -10, topic: 4))
    receive(telegram_message(3, "/observe on", user: 2, chat: -10, topic: 4))

    [1, 2].each do |id|
      assert_includes reply(id), "Observe: off"
      assert_includes reply(id), "Shared scope: this topic (4) in group -10."
      assert_includes reply(id), "Only the bot owner can change this setting."
    end
    assert_includes reply(3), "Only the bot owner"
    assert_empty @state.read.fetch("rooms")
    assert_empty @client.calls

    receive(telegram_message(4, "/observe on", chat: -10, topic: 4))
    receive(telegram_message(5, "/observe", user: 2, chat: -10, topic: 4))
    receive(telegram_message(6, "/observe status", user: 3, chat: -10, topic: 4))
    receive(telegram_message(7, "/observe off", user: 3, chat: -10, topic: 4))
    receive(telegram_message(8, "/observe status", user: 2, chat: -10, topic: 5))
    receive(telegram_message(9, "/observe", user: 3, chat: -20, topic: 4))

    [5, 6].each { |id| assert_includes reply(id), "Observe: on" }
    assert_includes reply(7), "Only the bot owner"
    [8, 9].each { |id| assert_includes reply(id), "Observe: off" }
    assert_equal({ "#{CONNECTION}:-10:4" => { "observe" => true } }, @state.read.fetch("rooms"))

    receive(telegram_message(10, "/observe off", chat: -10, topic: 4))
    receive(telegram_message(11, "/observe status", user: 2, chat: -10, topic: 4))

    assert_includes reply(11), "Observe: off"
    assert_equal({ "#{CONNECTION}:-10:4" => { "observe" => false } }, @state.read.fetch("rooms"))
    assert_empty @state.read.fetch("routes")
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_empty @bridge.speakers
    assert_empty @bridge.stops
  end

  private

    def allow_another_member_and_group
      @state.change do |document|
        document.fetch("access").fetch("allowed_users") << "3"
        document.fetch("access").fetch("allowed_chats") << "-20"
      end
    end

    def reply(id) = @state.read.fetch("deliveries").fetch("control:telegram:#{BOT}:#{CONNECTION}:42:#{id}:reply").fetch("text")
end
