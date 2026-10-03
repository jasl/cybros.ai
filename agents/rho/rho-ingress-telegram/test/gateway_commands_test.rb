require "support/runtime"

class TelegramGatewayCommandsTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_platform_help_and_menu_advertise_the_same_gateway_controls
    @runtime.consume(telegram_message(1, "/help"))
    text = @state.read.fetch("deliveries").fetch("control:1").fetch("text")
    menu = Rho::IngressTelegram::Commands::MENU

    assert_includes text, "In groups, mention me or reply to your task's receipt or answer."
    assert_includes text, "reply to a question message"
    assert_includes menu.map { |entry| entry.fetch(:command) }, "steer"
    assert_includes menu.map { |entry| entry.fetch(:command) }, "btw"
    menu.each { |entry| assert_includes text, "/#{entry.fetch(:command)}" }
    assert_empty @bridge.inputs
  end

  def test_empty_busy_commands_do_not_create_a_conversation_or_register_a_speaker
    @runtime.consume(telegram_message(1, "/steer@rho_bot \n\t"))
    @runtime.consume(telegram_message(2, "/btw"))

    assert_includes @state.read.fetch("deliveries").fetch("control:1").fetch("text"), "/steer <text>"
    assert_includes @state.read.fetch("deliveries").fetch("control:2").fetch("text"), "/btw <question>"
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_empty @bridge.speakers
  end

  def test_group_members_can_start_a_side_question_and_steer_their_own_task
    @runtime.consume(telegram_message(1, "/btw explain this", user: 2, chat: -10, topic: 4))
    @runtime.consume(telegram_message(2, "/steer change the explanation", user: 2, chat: -10, topic: 4, reply_to: 1, reply_user: 2))

    assert_equal ["side-1", "side-1"], @bridge.inputs.values.map { |input| input.fetch(:conversation_id) }
    assert_equal "loop-1", @bridge.inputs.values.last.fetch(:expected_steering_loop_public_id)
    assert_equal "steer", @bridge.inputs.values.last.fetch(:mode)
    assert_equal ["-10:4:2"], @state.read.fetch("routes").keys
    assert_empty @bridge.stops
  end

  def test_group_settings_show_the_speakers_own_choices_and_shared_topic_observation
    allow_another_member_and_group
    @runtime.consume(telegram_message(1, "/new", user: 2, chat: -10, topic: 4))
    @bridge.default_workspace = @bridge.workspace_rows.last
    @runtime.consume(telegram_message(2, "/new", user: 3, chat: -10, topic: 4))
    @bridge.default_workspace = @bridge.workspace_rows.first
    @state.change do |document|
      document.fetch("routes").fetch("-10:4:2").merge!("model" => "vendor/member-two", "voice" => "voice_only")
      document.fetch("routes").fetch("-10:4:3").merge!("model" => "vendor/member-three", "voice" => "all")
    end
    @client.admin = true
    @runtime.consume(telegram_message(3, "/observe on", chat: -10, topic: 4))
    routes = @state.read.fetch("routes")

    @runtime.consume(telegram_message(4, "/settings", user: 2, chat: -10, topic: 4))
    @runtime.consume(telegram_message(5, "/settings", user: 3, chat: -10, topic: 4))
    @runtime.consume(telegram_message(6, "/settings", user: 2, chat: -10, topic: 5))
    @runtime.consume(telegram_message(7, "/settings", user: 2, chat: -20, topic: 4))

    assert_includes reply(4), "Workspace: Home (workspace-home)"
    assert_includes reply(4), "Model: vendor/member-two"
    assert_includes reply(4), "Voice: voice_only"
    assert_includes reply(5), "Workspace: Project (workspace-project)"
    assert_includes reply(5), "Model: vendor/member-three"
    assert_includes reply(5), "Voice: all"
    [4, 5].each do |id|
      assert_includes reply(id), "Group behavior:"
      assert_includes reply(id), "Requests: explicit mentions or replies to the bot or a known task."
      assert_includes reply(id), "Observe: on"
      assert_includes reply(id), "Shared scope: this topic (4) in group -10."
      assert_includes reply(id), "Only the bot owner can change this setting."
      assert_includes reply(id), "Background context does not start the agent."
      assert_includes reply(id), "Your conversation settings in this topic (4) in group -10:"
    end
    [6, 7].each do |id|
      assert_includes reply(id), "Workspace: Home (workspace-home)"
      assert_includes reply(id), "Model: rho default"
      assert_includes reply(id), "Voice: off"
      assert_includes reply(id), "Observe: off"
    end
    assert_includes reply(6), "Shared scope: this topic (5) in group -10."
    assert_includes reply(7), "Shared scope: this topic (4) in group -20."
    assert_equal routes, @state.read.fetch("routes")
    assert_equal ["-10:4"], @state.read.fetch("rooms").keys
    assert_equal 2, @bridge.opened.length
    assert_empty @bridge.inputs
    assert_empty @bridge.speakers
    assert_empty @bridge.stops
  end

  def test_settings_distinguish_a_group_without_topics_from_a_private_chat
    @runtime.consume(telegram_message(1, "/settings", user: 2, chat: -10))
    @runtime.consume(telegram_message(2, "/settings", user: 2))

    assert_includes reply(1), "Shared scope: this group (-10)."
    assert_includes reply(1), "Your conversation settings in this group (-10):"
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
    @runtime.consume(telegram_message(1, "/observe", user: 2, chat: -10, topic: 4))
    @runtime.consume(telegram_message(2, "/observe status", user: 3, chat: -10, topic: 4))
    @runtime.consume(telegram_message(3, "/observe on", user: 2, chat: -10, topic: 4))

    [1, 2].each do |id|
      assert_includes reply(id), "Observe: off"
      assert_includes reply(id), "Shared scope: this topic (4) in group -10."
      assert_includes reply(id), "Only the bot owner can change this setting."
    end
    assert_includes reply(3), "Only the bot owner"
    assert_empty @state.read.fetch("rooms")
    assert_empty @client.calls

    @runtime.consume(telegram_message(4, "/observe on", chat: -10, topic: 4))
    @runtime.consume(telegram_message(5, "/observe", user: 2, chat: -10, topic: 4))
    @runtime.consume(telegram_message(6, "/observe status", user: 3, chat: -10, topic: 4))
    @runtime.consume(telegram_message(7, "/observe off", user: 3, chat: -10, topic: 4))
    @runtime.consume(telegram_message(8, "/observe status", user: 2, chat: -10, topic: 5))
    @runtime.consume(telegram_message(9, "/observe", user: 3, chat: -20, topic: 4))

    [5, 6].each { |id| assert_includes reply(id), "Observe: on" }
    assert_includes reply(7), "Only the bot owner"
    [8, 9].each { |id| assert_includes reply(id), "Observe: off" }
    assert_equal({ "-10:4" => { "observe" => true } }, @state.read.fetch("rooms"))

    @runtime.consume(telegram_message(10, "/observe off", chat: -10, topic: 4))
    @runtime.consume(telegram_message(11, "/observe status", user: 2, chat: -10, topic: 4))

    assert_includes reply(11), "Observe: off"
    assert_equal({ "-10:4" => { "observe" => false } }, @state.read.fetch("rooms"))
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

    def reply(id) = @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")
end
