require "support/runtime"

class TelegramPersistenceRecoveryTest < Minitest::Test
  include TelegramRuntimeSupport

  class UncertainStore < TelegramStateSupport::Store
    attr_accessor :lose_status, :offline

    def update(id, value:, lock_version:)
      status = value.dig("deliveries", "reply", "status")
      if status == @lose_status
        @lose_status = nil
        # For sending, commit then lose the response. For sent, lose the write
        # before commit: Telegram may have delivered, but Nexus still says sending.
        super if status == "sending"
        @offline = true
        raise CybrosAgent::TransportError, "Nexus unavailable"
      end
      super
    end

    def list(**)
      raise CybrosAgent::TransportError, "Nexus unavailable" if @offline

      super
    end
  end

  def test_unconfirmed_sending_receipt_recovers_without_restart_or_external_send
    sender, store = persistence_sender
    store.lose_status = "sending"
    assert_raises(CybrosAgent::TransportError) { sender.flush }
    assert_empty @client.calls
    store.offline = false
    sender.flush
    assert_empty @client.calls
    assert_equal "uncertain", @state.read.fetch("deliveries").fetch("reply").fetch("status")
    assert_equal ["uncertain"], @runtime.status.fetch("delivery_issues").map { |row| row.fetch("status") }
  end

  def test_unconfirmed_success_is_never_sent_again_when_nexus_returns
    sender, store = persistence_sender
    store.lose_status = "sent"
    assert_raises(CybrosAgent::TransportError) { sender.flush }
    assert_equal ["sendMessage"], @client.calls.map(&:first)
    store.offline = false
    sender.flush
    assert_equal ["sendMessage"], @client.calls.map(&:first)
    assert_equal "uncertain", @state.read.fetch("deliveries").fetch("reply").fetch("status")
  end

  def test_status_exposes_unavailable_database_without_guessing_empty_state
    @state = Rho::IngressTelegram::State.new(store: Rho::StoreDocument.new(
      store: -> { raise Rho::ConnectionError, "offline" }, namespace: "rho.telegram", key: "state"))
    result = Rho::IngressTelegram::Runtime.new(settings: @settings, state: @state, bridge: @bridge,
      client: @client, log: nil).status
    assert_equal({ "enabled" => true, "connection" => "waiting_for_nexus" }, result)
  end

  private

    def persistence_sender
      store = UncertainStore.new
      @state = Rho::IngressTelegram::State.new(store: Rho::StoreDocument.new(
        store: -> { store }, namespace: "rho.telegram", key: "state"))
      @runtime = runtime
      @state.enqueue("reply", route: { "chat_id" => "1", "group" => false }, text: "Answer")
      sender = Rho::IngressTelegram::Delivery.new(client: @client, state: @state, clock: -> { @now })
      [sender, store]
    end
end
