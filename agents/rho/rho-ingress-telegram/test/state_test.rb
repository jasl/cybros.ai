require "test_helper"

class TelegramStateTest < Minitest::Test
  def setup
    @store = TelegramStateSupport::Store.new
    @state = state
  end

  def test_applied_update_survives_restart_until_its_connection_advances
    receipt = { "connection_public_id" => "connection", "update" => { "update_id" => 10 },
      "request" => { "owner_id" => "member", "conversation_id" => "original" } }
    assert_equal receipt, @state.stage(receipt)
    @state.consumed(10)
    @state = state

    assert @state.read.fetch("pending_update").fetch("processed")
    assert_equal receipt.fetch("request"), @state.read.fetch("pending_update").fetch("request")
    @state.acknowledge(11, connection_public_id: "other-connection")
    assert @state.read["pending_update"]
    @state.acknowledge(10, connection_public_id: "connection")
    assert @state.read["pending_update"]
    @state.acknowledge(11, connection_public_id: "connection")
    assert_nil @state.read["pending_update"]
  end

  def test_a_new_update_cannot_replace_an_unacknowledged_receipt
    first = { "connection_public_id" => "connection", "update" => { "update_id" => 10 } }
    @state.stage(first)
    assert_equal first, @state.stage(first.merge("update" => { "update_id" => 11 }))
    assert_raises(Rho::StateError) { @state.consumed(11) }
    refute @state.read.fetch("pending_update").key?("processed")
    @state.acknowledge(20, connection_public_id: "connection")
    assert_equal first, @state.read.fetch("pending_update")
  end

  def test_delivery_routes_preserve_original_targets_without_owning_bot_current_or_requester
    routes = { "connection:-10:4" => { "chat_id" => "-10", "topic_id" => 4, "group" => true,
      "connection_public_id" => "connection", "conversations" => { "old" => { "workspace_public_id" => "original" } } } }
    @state.change { |document| document["routes"] = routes }
    @state = state

    assert_equal routes, @state.read.fetch("routes")
    assert_equal "connection", @state.binding("old").fetch("connection_public_id")
    refute @state.read.fetch("routes").values.any? { |route| route.key?("owner_id") || route.key?("current") }
    @state.change { |document| document.fetch("speakers")["another-member"] = "another-speaker" }
    assert_equal routes, @store.rows.values.first.value.fetch("routes")
  end

  private

    def state
      Rho::IngressTelegram::State.new(store: Rho::StoreDocument.new(store: -> { @store }, namespace: "rho.telegram", key: "state"))
    end
end
