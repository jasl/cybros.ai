require "support/runtime"

class TelegramAccessWorkflowTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_owner_commands_at_the_fixed_group_target_change_live_admission_and_survive_restart
    receive(telegram_message(1, "/access users add 9", chat: -10, topic: 4))
    receive(group_message(2, "@rho_bot newly allowed", user: 9))
    assert_includes @bridge.inputs.values.last.fetch(:text), "newly allowed"
    @runtime = runtime
    receive(telegram_message(3, "/access users list", chat: -10, topic: 4))
    assert_includes feedback(3), "Bot owner: 1"
    assert_includes feedback(3), "9"
    receive(telegram_message(4, "/access users remove 9", chat: -10, topic: 4))
    receive(group_message(5, "@rho_bot no longer allowed", user: 9))

    assert_equal 1, @bridge.inputs.length
    assert_equal ["2"], @state.read.fetch("access").fetch("allowed_users")
    assert_empty @bridge.stops
  end

  def test_only_the_owner_can_manage_access_at_the_fixed_group_target
    receive(telegram_message(1, "/access users add 9", user: 2, chat: -10, topic: 4))
    receive(telegram_message(2, "/ignore add 9", user: 2, chat: -10, topic: 4))
    receive(telegram_message(3, "/access chats add -20", user: 2, chat: -10, topic: 4))

    assert_includes feedback(1), "Only the bot owner"
    assert_includes feedback(2), "Only the bot owner"
    assert_includes feedback(3), "Only the bot owner"
    assert_equal ["2"], @state.read.fetch("access").fetch("allowed_users")
    assert_equal ["-10"], @state.read.fetch("access").fetch("allowed_chats")
    assert_empty @state.read.fetch("access").fetch("ignored_users")
  end

  def test_access_replay_acknowledges_the_saved_result_without_reapplying_the_change
    consumed = @state.method(:consumed)
    interrupt = true
    @state.define_singleton_method(:consumed) do |id|
      if id == 1 && interrupt
        interrupt = false
        raise Rho::ConnectionError, "process stopped before acknowledgement"
      end
      consumed.call(id)
    end
    update = telegram_message(1, "/access users add 9")
    assert_raises(Rho::ConnectionError) { receive(update) }
    persisted = @state.read
    assert_includes persisted.fetch("access").fetch("allowed_users"), "9"
    assert_equal "applied", persisted.fetch("pending_update").fetch("control_status")
    result = feedback(1)
    @state.change { |document| document.fetch("access").fetch("allowed_users").delete("9") }
    @runtime = runtime
    receive(update)
    receive(update)

    assert_equal result, feedback(1)
    refute_includes @state.read.fetch("access").fetch("allowed_users"), "9"
    assert_nil @state.read["pending_update"]
    assert_equal 2, @connection_state.read.fetch("offset")
  end

  def test_ignore_silences_future_commands_mentions_and_observation_but_keeps_accepted_delivery
    @client.admin = true
    receive(telegram_message(1, "/observe on", chat: -10, topic: 4))
    receive(telegram_message(2, "@rho_bot accepted", user: 2, chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    receive(telegram_message(3, "/ignore add 2", chat: -10, topic: 4))
    receive(telegram_message(4, "ignored background", user: 2, chat: -10, topic: 4))
    receive(telegram_message(5, "@rho_bot ignored mention", user: 2, chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    receive(telegram_message(6, "/start", user: 2, chat: -10, topic: 4))
    receive(telegram_message(7, "/stop", user: 2, chat: -10, topic: 4, reply_to: 2, reply_user: 2))

    assert_equal 1, @bridge.inputs.length
    assert_equal 1, @bridge.opened.length
    assert_equal [1, 3].map { |id| "control:telegram:#{BOT}:#{CONNECTION}:42:#{id}:reply" }, @state.read.fetch("deliveries").keys
    assert_equal ["2"], @state.read.fetch("access").fetch("allowed_users")
    assert_equal ["2"], @state.read.fetch("access").fetch("ignored_users")
    @state.change { |document| document.fetch("deliveries").clear }
    @bridge.turn_rows["conversation-1"] = [turn(0, "Previously accepted answer")]
    @runtime = runtime
    @runtime.tick

    formal = @client.calls.find { |method, params| method == "sendMessage" && params[:text] == "Previously accepted answer" }
    assert_equal "-10", formal.last.fetch(:chat_id)
    assert_equal 4, formal.last.fetch(:message_thread_id)
    assert_equal 2, formal.last.fetch(:reply_parameters).fetch(:message_id)
    assert_empty @bridge.stops
  end

  def test_removing_a_group_still_blocks_new_input_and_delivery_to_that_group
    receive(group_message(1, "@rho_bot accepted", user: 2))
    receive(telegram_message(2, "/access chats remove -10", chat: -10, topic: 4))
    receive(group_message(3, "@rho_bot rejected", user: 2))
    @bridge.turn_rows["conversation-1"] = [turn(0, "Held answer")]
    @runtime.tick

    assert_equal 1, @bridge.inputs.length
    refute @client.calls.any? { |_method, params| params[:chat_id] == "-10" }
    assert_empty @bridge.stops
    assert_equal "conversation-1", @bridge.bot_detail.fetch("current").fetch("public_id")
  end

  private

    def group_message(id, text, user:)
      telegram_message(id, text, user: user, chat: -10, topic: 4,
        entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }])
    end

    def feedback(id) = @state.read.fetch("deliveries").fetch("control:telegram:#{BOT}:#{CONNECTION}:42:#{id}:reply").fetch("text")
end
