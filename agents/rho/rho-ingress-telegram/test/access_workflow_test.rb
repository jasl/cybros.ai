require "support/runtime"

class TelegramAccessWorkflowTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_owner_private_commands_change_live_admission_and_survive_restart
    @runtime.consume(telegram_message(1, "/access users add 9"))
    @runtime.consume(telegram_message(2, "newly allowed", user: 9))
    assert_equal "newly allowed", @bridge.inputs.values.last.fetch(:text)
    @runtime = runtime
    @runtime.consume(telegram_message(3, "/access users list"))
    assert_includes feedback(3), "Bot owner: 1"
    assert_includes feedback(3), "9"
    @runtime.consume(telegram_message(4, "/access users remove 9"))
    @runtime.consume(telegram_message(5, "no longer allowed", user: 9))

    assert_equal 1, @bridge.inputs.length
    assert_equal ["2"], @state.read.fetch("access").fetch("allowed_users")
    assert_empty @bridge.stops
  end

  def test_only_owner_private_chat_can_manage_access
    @runtime.consume(telegram_message(1, "/access users add 9", user: 2))
    @runtime.consume(telegram_message(2, "/ignore add 2", chat: -10))
    @runtime.consume(telegram_message(3, "/access chats add -20", chat: -10))

    assert_includes feedback(1), "Only the bot owner"
    assert_includes feedback(2), "private chat"
    assert_includes feedback(3), "private chat"
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
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    persisted = @state.read
    assert_includes persisted.fetch("access").fetch("allowed_users"), "9"
    assert_equal "applied", persisted.fetch("pending_update").fetch("control_status")
    result = feedback(1)
    @state.change { |document| document.fetch("access").fetch("allowed_users").delete("9") }
    @runtime = runtime
    @runtime.consume(update)
    @runtime.consume(update)

    assert_equal result, feedback(1)
    refute_includes @state.read.fetch("access").fetch("allowed_users"), "9"
    assert_nil @state.read["pending_update"]
    assert_equal 2, @state.read.fetch("offset")
  end

  def test_ignore_silences_future_private_start_group_mentions_and_observation
    @client.admin = true
    @runtime.consume(telegram_message(1, "/observe on", chat: -10, topic: 4))
    @runtime.consume(telegram_message(2, "@rho_bot accepted", user: 2, chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    @runtime.consume(telegram_message(3, "/ignore add 2"))
    @runtime.consume(telegram_message(4, "ignored background", user: 2, chat: -10, topic: 4))
    @runtime.consume(telegram_message(5, "@rho_bot ignored mention", user: 2, chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    @runtime.consume(telegram_message(6, "/start", user: 2))
    @runtime.consume(telegram_message(7, "/stop", user: 2, chat: -10, topic: 4, reply_to: 2, reply_user: 2))

    assert_equal 1, @bridge.inputs.length
    assert_equal 1, @bridge.opened.length
    assert_equal %w[control:1 control:2 control:3], @state.read.fetch("deliveries").keys
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
    @runtime.consume(telegram_message(1, "@rho_bot accepted", user: 2, chat: -10,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    @runtime.consume(telegram_message(2, "/access chats remove -10"))
    @runtime.consume(telegram_message(3, "@rho_bot rejected", user: 2, chat: -10,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    @bridge.turn_rows["conversation-1"] = [turn(0, "Held answer")]
    @runtime.tick

    assert_equal 1, @bridge.inputs.length
    refute @client.calls.any? { |_method, params| params[:chat_id] == "-10" }
    assert_empty @bridge.stops
    assert_equal "conversation-1", @state.read.fetch("routes").fetch("-10:0:2").fetch("current")
  end

  private

    def feedback(id) = @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")
end
