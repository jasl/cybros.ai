require "test_helper"
require "support/runtime"

class TelegramSharedConnectionTest < Minitest::Test
  CONNECTION = TelegramRuntimeSupport::CONNECTION
  BOT = TelegramRuntimeSupport::BOT
  OTHER = "019a1111-2222-7333-8444-777777777777".freeze
  Host = Data.define(:config)

  class Binding
    attr_reader :updates, :acknowledgments
    attr_accessor :settings, :failure

    def initialize(settings)
      @settings, @updates, @acknowledgments = settings, [], []
    end

    def consume(update, connection_public_id:, bot:)
      @updates << [update, connection_public_id, bot]
      raise failure if failure
    end

    def acknowledge(offset, connection_public_id:)
      @acknowledgments << [offset, connection_public_id]
    end
  end

  def setup
    @directory = Dir.mktmpdir("rho-shared-telegram")
    @home = Struct.new(:root).new(@directory)
    @state = Rho::IngressTelegram::ConnectionState.new(store: TelegramStateSupport.document(@home, key: "connection"))
    @bindings = { BOT => Binding.new(settings(-10, 4)), OTHER => Binding.new(settings(-10, 5)) }
    @client = TelegramRuntimeSupport::Client.new
    @now = 1000.0
    @connection = connection
    @connection.identify("id" => 42, "username" => "rho_bot")
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_one_offset_routes_each_exact_topic_to_its_bot_and_consumes_unbound_updates
    @connection.consume(update(1, 4))
    @connection.consume(update(2, 5))
    @connection.consume(update(3, 6))
    @connection.consume(update(1, 4))

    assert_equal [1], @bindings.fetch(BOT).updates.map { |row| row.first.fetch("update_id") }
    assert_equal [2], @bindings.fetch(OTHER).updates.map { |row| row.first.fetch("update_id") }
    assert_equal 4, @state.read.fetch("offset")
    assert_nil @state.read["pending_update"]
    assert_equal [4, CONNECTION], @bindings.fetch(BOT).acknowledgments.last
    assert_equal [4, CONNECTION], @bindings.fetch(OTHER).acknowledgments.last
  end

  def test_recovery_keeps_the_original_bot_when_its_configured_target_changes
    @bindings.fetch(BOT).failure = Rho::ConnectionError.new("response lost")
    assert_raises(Rho::ConnectionError) { @connection.consume(update(1, 4)) }
    assert_equal BOT, @state.read.fetch("pending_update").fetch("agent_public_id")
    assert_nil @state.read["offset"]
    @bindings.fetch(BOT).settings = settings(-20, 4)
    @bindings.fetch(OTHER).settings = settings(-10, 4)
    @bindings.fetch(BOT).failure = nil
    @connection = connection
    @connection.identify("id" => 42, "username" => "rho_bot")
    @connection.consume(update(1, 4))

    assert_equal [1, 1], @bindings.fetch(BOT).updates.map { |row| row.first.fetch("update_id") }
    assert_empty @bindings.fetch(OTHER).updates
    assert_equal 2, @state.read.fetch("offset")
  end

  def test_missing_original_binding_preserves_the_pending_receipt_and_offset
    @state.stage(update: update(1, 4), agent_public_id: BOT)
    @bindings.delete(BOT)

    assert_raises(Rho::ConnectionError) { @connection.consume(update(1, 4)) }
    assert_equal BOT, @state.read.fetch("pending_update").fetch("agent_public_id")
    assert_nil @state.read["offset"]
    assert_empty @bindings.fetch(OTHER).updates
  end

  def test_retry_after_and_chat_budget_are_shared_by_all_bot_sends
    a = { "chat_id" => "-10", "group" => true }
    b = { "chat_id" => "-20", "group" => true }
    assert @connection.ready?(a)
    @connection.with_send(a) { :sent }
    refute @connection.ready?(a)
    refute @connection.ready?(b), "The physical bot has one global send rate"
    @now += 0.04
    assert @connection.ready?(b)
    @connection.throttle(9)
    @connection = connection
    refute @connection.ready?(b), "Telegram retry-after survives a worker restart"
    @now += 9
    assert @connection.ready?(b)
  end

  def test_a_connection_cannot_change_its_physical_identity
    assert_raises(Rho::ConfigurationError) { @connection.identify("id" => 99, "username" => "other_bot") }
    assert_equal "42", @state.read.fetch("bot_id")
    assert_equal 42, @connection.bot.fetch("id")
  end

  def test_original_conversation_binding_is_projected_with_the_bot_identity
    document = { "connections" => { CONNECTION => { "token" => "synthetic" } },
      "bots" => { BOT => settings(-10, 4).to_h } }
    coordinator = Rho::IngressTelegram::Coordinator.new(host: Host.new(config: Rho::Config.from_hash({})),
      settings: Rho::IngressTelegram::Settings.bindings(document), connections: Rho::IngressTelegram::Settings.connections(document))
    bot_state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home, key: "bot"))
    bot_state.change do |value|
      value.fetch("routes")["original"] = { "chat_id" => "-10", "topic_id" => 4, "connection_public_id" => CONNECTION,
        "conversations" => { "conversation" => { "workspace_public_id" => "workspace" } } }
    end
    coordinator.instance_variable_get(:@bindings).fetch(BOT).state = bot_state

    assert_equal({ "channel" => "telegram", "label" => "Telegram · Chat -10 · Topic 4", "chat_id" => "-10",
      "topic_id" => 4, "connection_public_id" => CONNECTION, "agent_public_id" => BOT }, coordinator.binding("conversation"))
    assert_nil coordinator.binding("other-conversation")
  end

  private

    def settings(chat, topic)
      Rho::IngressTelegram::Settings.new("enabled" => true, "connection_public_id" => CONNECTION,
        "target" => { "chat_id" => chat.to_s, "topic_id" => topic })
    end

    def connection
      Rho::IngressTelegram::Connection.new(public_id: CONNECTION, client: @client, state: @state,
        bindings: -> { @bindings }, log: nil, clock: -> { @now })
    end

    def update(id, topic)
      { "update_id" => id, "message" => { "message_id" => id, "date" => @now.to_i, "text" => "hello",
        "from" => { "id" => 2 }, "chat" => { "id" => -10, "type" => "supergroup" },
        "is_topic_message" => true, "message_thread_id" => topic } }
    end
end
