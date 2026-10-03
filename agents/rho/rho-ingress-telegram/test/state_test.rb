require "test_helper"

class TelegramStateTest < Minitest::Test
  def setup
    @store = TelegramStateSupport::Store.new
    @state = Rho::IngressTelegram::State.new(store: Rho::StoreDocument.new(
      store: -> { @store }, namespace: "rho.telegram", key: "state"))
  end

  def test_missing_private_route_owner_is_available_on_read_and_persisted_on_change
    seed_routes("1:0" => { "chat_id" => "1", "group" => false },
      "2:0" => { "chat_id" => "2", "group" => false, "owner_id" => nil })

    assert_equal "1", @state.read.fetch("routes").fetch("1:0").fetch("owner_id")
    assert_equal "2", @state.read.fetch("routes").fetch("2:0").fetch("owner_id")
    @state.consumed(10)
    assert_equal "1", @store.rows.values.first.value.fetch("routes").fetch("1:0").fetch("owner_id")
  end

  def test_route_defaults_preserve_known_owners_and_never_infer_group_or_unknown_route_ownership
    routes = { "1:0" => { "chat_id" => "1", "group" => false, "owner_id" => "2" },
      "-10:4:2" => { "chat_id" => "-10", "group" => true },
      "-10:4:3" => { "chat_id" => "-10", "group" => true, "owner_id" => "3" },
      "unknown" => { "chat_id" => "4" } }
    seed_routes(routes)

    assert_equal routes, @state.read.fetch("routes")
    @state.consumed(10)
    assert_equal routes, @store.rows.values.first.value.fetch("routes")
  end

  private

    def seed_routes(routes)
      @store.create(namespace: "rho.telegram", key: "state", value: { "routes" => routes }, idempotency_key: "seed")
    end
end
