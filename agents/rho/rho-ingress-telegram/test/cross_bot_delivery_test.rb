require "support/runtime"

class TelegramCrossBotDeliveryTest < Minitest::Test
  include TelegramRuntimeSupport

  TARGET = "019a0000-0000-7000-8000-000000000002"

  def setup
    super
    @target_state = Rho::IngressTelegram::State.new(store: Rho::StoreDocument.new(
      namespace: "rho.telegram", key: "target", store: -> { @target_store }))
    @target_store = TelegramStateSupport::Store.new
    @target_client = Client.new
    @target_delivery = Rho::IngressTelegram::Delivery.new(client: @target_client, state: @target_state,
      limits: Rho::IngressTelegram::RateLimit.new(clock: -> { @now }), clock: -> { @now })
    @source_delivery = Rho::IngressTelegram::Delivery.new(client: @client, state: @state,
      limits: Rho::IngressTelegram::RateLimit.new(clock: -> { @now }), clock: -> { @now },
      destination: ->(entry) { entry["destination_agent_public_id"] ? @target_delivery : nil })
    @state.change do |document|
      document.fetch("requests")["request"] = { "room_key" => "#{CONNECTION}:1:0", "message_id" => 9 }
      document.fetch("messages")["#{CONNECTION}:1:0"] = "source-message"
    end
    @state.enqueue("cross", route: { "chat_id" => "1", "group" => false }, text: "Delegated answer",
      request_id: "request", destination_agent_public_id: TARGET)
  end

  def test_target_sends_while_only_source_owns_the_delivery_receipt
    @source_delivery.flush

    assert_empty @client.calls
    assert_equal ["sendMessage"], @target_client.calls.map(&:first)
    refute @target_client.calls.first.last.key?(:reply_parameters)
    receipt = @state.read.fetch("deliveries").fetch("cross")
    assert_equal "sent", receipt.fetch("status")
    assert_equal [1001], receipt.fetch("message_ids")
    assert_equal TARGET, receipt.fetch("destination_agent_public_id")
    assert_equal "source-message", @state.read.fetch("messages").fetch("#{CONNECTION}:1:0")
    assert_empty @target_state.read.fetch("deliveries")
  end

  def test_target_429_holds_its_own_messages_but_not_the_source_bot
    @target_client.failure = Rho::IngressTelegram::Client::Refused.new(code: 429, description: "wait", retry_after: 8)
    @source_delivery.flush
    @state.enqueue("local", route: { "chat_id" => "2", "group" => false }, text: "Source answer")
    @target_state.enqueue("local", route: { "chat_id" => "3", "group" => false }, text: "Target answer")
    @source_delivery.flush
    @target_delivery.flush
    @target_delivery.progress({ "chat_id" => "4", "group" => false }, "target", @bridge.current)

    assert_equal 1, @target_client.calls.length
    assert_equal ["Source answer"], @client.calls.map { |_method, values| values.fetch(:text) }
    assert_equal 1_008, @target_state.read.fetch("retry_at")
    refute @state.read.key?("retry_at")
    assert_equal "pending", @state.read.fetch("deliveries").fetch("cross").fetch("status")
    @now += 8
    @source_delivery.flush
    assert_equal "sent", @state.read.fetch("deliveries").fetch("cross").fetch("status")
  end

  def test_ambiguous_target_post_keeps_source_uncertain_and_never_sends_as_source
    @target_client.failure = Rho::IngressTelegram::Client::Unavailable.new(reason: :read, ambiguous: true)
    @source_delivery.flush
    @state.recover_deliveries
    @source_delivery.flush

    assert_empty @client.calls
    assert_equal 1, @target_client.calls.length
    assert_equal "uncertain", @state.read.fetch("deliveries").fetch("cross").fetch("status")
    assert_empty @target_state.read.fetch("deliveries")
  end

  def test_destination_refusal_is_visible_and_never_falls_back_to_the_source_client
    sender = Rho::IngressTelegram::Delivery.new(client: @client, state: @state,
      destination: ->(_entry) { raise Rho::IngressTelegram::Delivery::Unavailable, "Target chat unavailable" })
    sender.flush

    assert_empty @client.calls
    assert_empty @target_client.calls
    assert_equal "refused", @state.read.fetch("deliveries").fetch("cross").fetch("status")
    assert_equal "destination_unavailable", @state.read.fetch("deliveries").fetch("cross").fetch("error_code")
    assert_equal "Target chat unavailable", @state.read.fetch("deliveries").fetch("cross").fetch("error")
  end
end
