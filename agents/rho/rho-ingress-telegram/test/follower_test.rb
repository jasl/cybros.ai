require "support/runtime"

class TelegramFollowerTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_first_turn_waits_for_completion_across_restart_and_delivers_once
    @runtime.consume(telegram_message(1, "start"))
    @bridge.turn_rows["conversation-1"] = [turn(0, "", status: "running")]
    @runtime.tick
    assert_nil @state.read.fetch("routes").dig("1:0", "conversations", "conversation-1", "position")

    @runtime = runtime
    @bridge.turn_rows["conversation-1"] = [turn(0, "The first answer")]
    @runtime.tick
    assert_equal 0, @state.read.fetch("routes").dig("1:0", "conversations", "conversation-1", "position")
    assert_equal 1, @client.calls.count { |method, params| method == "sendMessage" && params[:text] == "The first answer" }
    @runtime = runtime
    @runtime.tick
    assert_equal 1, @client.calls.count { |method, params| method == "sendMessage" && params[:text] == "The first answer" }
  end
end
