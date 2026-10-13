require "support/runtime"

class TelegramWelcomeTest < Minitest::Test
  include TelegramRuntimeSupport

  WELCOME = "Hello **friend**. I can help with your questions.".freeze
  NEW_CONVERSATION = "Started a new conversation. Earlier work still reports back here.".freeze

  class Bridge < TelegramRuntimeSupport::Bridge
    def bot_detail = super.merge("effective_welcome_message" => WELCOME)
  end

  def setup
    super
    @bridge = Bridge.new
    @runtime = runtime
  end

  def test_start_delivers_plain_welcome_once_across_duplicate_updates_and_restart
    start = telegram_message(1, "/start", chat: -10, topic: 4)
    receive(start)
    flush_deliveries

    assert_equal [{ chat_id: "-10", message_thread_id: 4, text: WELCOME }], welcome_messages
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_empty @bridge.speakers

    receive(start)
    receive(telegram_message(2, "/start", chat: -10, topic: 4))
    flush_deliveries
    restart_runtime
    receive(telegram_message(2, "/start", chat: -10, topic: 4))
    receive(telegram_message(3, "/start", chat: -10, topic: 4))
    flush_deliveries

    assert_equal 1, welcome_messages.length
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_empty @bridge.speakers
  end

  def test_new_has_its_own_static_confirmation_and_does_not_repeat_the_welcome
    receive(telegram_message(1, "/new", chat: -10, topic: 4))
    flush_deliveries

    assert_equal [WELCOME, NEW_CONVERSATION], messages.map { |params| params.fetch(:text) }
    assert_equal 1, @bridge.opened.length
    assert_empty @bridge.inputs
    assert_empty @bridge.speakers

    restart_runtime
    receive(telegram_message(2, "/new", chat: -10, topic: 4))
    flush_deliveries

    assert_equal [WELCOME, NEW_CONVERSATION, NEW_CONVERSATION], messages.map { |params| params.fetch(:text) }
    assert_equal 2, @bridge.opened.length
    assert_empty @bridge.inputs
    assert_empty @bridge.speakers
  end

  def test_first_ordinary_interaction_delivers_welcome_without_an_extra_model_input
    request = telegram_message(1, "@rho_bot explain this", user: 2, chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }])
    receive(request)
    flush_deliveries

    assert_equal 1, welcome_messages.length
    assert_equal ["@rho_bot explain this"], @bridge.inputs.values.map { |input| input.fetch(:text) }
    assert_equal ["speaker-2"], @bridge.inputs.values.map { |input| input.fetch(:speaker) }

    restart_runtime
    receive(request)
    flush_deliveries

    assert_equal 1, welcome_messages.length
    assert_equal 1, @bridge.inputs.length
    assert_equal 1, @bridge.opened.length
  end

  private

    def messages
      @client.calls.filter_map { |method, params| params if method == "sendMessage" }
    end

    def welcome_messages = messages.select { |params| params[:text] == WELCOME }

    def flush_deliveries
      @runtime.tick
      @now += 3
      @runtime.tick
    end

    def restart_runtime
      @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
      @connection_state = Rho::IngressTelegram::ConnectionState.new(store: TelegramStateSupport.document(@home, key: "connection"))
      @runtime = runtime
    end
end
