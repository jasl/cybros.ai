require "support/runtime"

class TelegramBotSelectionRecoveryTest < Minitest::Test
  include TelegramRuntimeSupport

  # Core can commit the target and archive its predecessor before publishing
  # current. Its next mutation recovers that pending switch; detail stays read-only.
  class Bridge < TelegramRuntimeSupport::Bridge
    attr_accessor :lose_switch_response, :lose_selection_response

    def new_bot_conversation(**fields)
      previous = @bot_current
      result = super
      if @lose_switch_response
        @lose_switch_response = false
        @pending_current, @bot_current = @bot_current, previous
        raise Rho::ConnectionError, "archive committed; switch response lost"
      end
      result
    end

    def ensure_bot_current(operation_id:)
      if @pending_current
        @bot_current, @pending_current = @pending_current, nil
      end
      selected = @bot_operations[operation_id]
      unless selected
        selected = super.fetch("selected")
        @bot_operations[operation_id] = selected
      end
      if @lose_selection_response
        @lose_selection_response = false
        raise Rho::ConnectionError, "selection committed; response lost"
      end
      { "selected" => selected, "current" => @bot_current, "replayed" => true }
    end
  end

  def setup
    super
    @bridge = Bridge.new
    @runtime = runtime
  end

  def test_new_input_recovers_an_interrupted_browser_switch_before_selecting_its_conversation
    receive(telegram_message(1, "Initial request"))
    @bridge.lose_switch_response = true
    assert_raises(Rho::ConnectionError) { @bridge.new_bot_conversation(operation_id: "browser-new") }
    assert_equal "conversation-1", @bridge.bot_detail.dig("current", "public_id")
    @runtime = runtime

    receive(telegram_message(2, "First request after recovery"))

    assert_equal "conversation-2", @bridge.bot_detail.dig("current", "public_id")
    assert_equal ["conversation-1", "conversation-2"], @bridge.inputs.values.map { |row| row.fetch(:conversation_id) }
    assert_equal ["Initial request", "First request after recovery"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert_empty @state.read.fetch("pending_inputs")
    assert_empty @bridge.stops
  end

  def test_lost_selection_response_replays_its_original_target_after_a_later_switch
    receive(telegram_message(1, "Initial request"))
    @bridge.lose_selection_response = true
    incoming = telegram_message(2, "Must not move to the later conversation")
    assert_raises(Rho::ConnectionError) { consume(incoming) }
    @bridge.new_bot_conversation(operation_id: "later-browser-new")
    @runtime = runtime

    receive(incoming)

    assert_equal "conversation-2", @bridge.bot_detail.dig("current", "public_id")
    assert_equal ["Initial request"], @bridge.inputs.values.map { |row| row.fetch(:text) }
    assert_empty @state.read.fetch("pending_inputs")
    assert_equal 2, @bridge.opened.length
  end
end
