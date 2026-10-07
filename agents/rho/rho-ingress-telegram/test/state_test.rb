require "test_helper"

class TelegramStateTest < Minitest::Test
  def setup
    @store = TelegramStateSupport::Store.new
    @state = Rho::IngressTelegram::State.new(store: Rho::StoreDocument.new(
      store: -> { @store }, namespace: "rho.telegram", key: "state"))
  end

  def test_missing_route_owner_is_refused_without_changing_the_stored_route
    assert_invalid_owner({})
  end

  def test_null_route_owner_is_refused_without_changing_the_stored_route
    assert_invalid_owner("owner_id" => nil)
  end

  def test_empty_route_owner_is_refused_without_changing_the_stored_route
    assert_invalid_owner("owner_id" => "")
  end

  def test_route_defaults_preserve_authored_ownership
    routes = { "1:0" => { "chat_id" => "1", "group" => false, "owner_id" => "2" },
      "-10:4:3" => { "chat_id" => "-10", "group" => true, "owner_id" => "3" } }
    seed_routes(routes)

    assert_equal routes, @state.read.fetch("routes")
    @state.consumed(10)
    assert_equal routes, @store.rows.values.first.value.fetch("routes")
  end

  private

    def assert_invalid_owner(fields)
      routes = { "1:0" => { "chat_id" => "1", "group" => false }.merge(fields) }
      seed_routes(routes)
      assert_raises(Rho::StateError) { @state.read }
      assert_raises(Rho::StateError) { @state.consumed(10) }
      assert_equal({ "routes" => routes }, @store.rows.values.first.value)
    end

    def seed_routes(routes)
      @store.create(namespace: "rho.telegram", key: "state", value: { "routes" => routes }, idempotency_key: "seed")
    end
end
