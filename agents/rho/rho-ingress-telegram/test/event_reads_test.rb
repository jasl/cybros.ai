require "support/runtime"
require "support/bridge"

class TelegramEventReadsTest < Minitest::Test
  include TelegramRuntimeSupport

  def setup
    super
    @event_source = { page: CybrosAgent::Api::ConversationEventPage.new(items: [], next_after: nil, watermark: 0) }
    source = @event_source
    context = Object.new
    context.define_singleton_method(:events) do |**|
      raise source.fetch(:error) if source[:error]

      source.fetch(:page)
    end
    member = TelegramBridgeSupport::Member.new
    member.define_singleton_method(:conversation) { |_| context }
    plane = Rho::Extensions::MemberPlane.new(client: member, workspace_public_id: "workspace-home")
    host = TelegramBridgeSupport::Host.new(home: nil, member_plane: ->(**) { plane })
    event_bridge = Rho::IngressTelegram::Bridge.new(host: host, core: @bridge)
    @bridge.define_singleton_method(:events) { |*args, **fields| event_bridge.events(*args, **fields) }
    @runtime.define_singleton_method(:sleep) { |_| }
  end

  def test_missing_events_consume_steer_without_replaying_or_blocking_later_updates
    assert_control_refused("/steer keep the original goal", CybrosAgent::Api::NotFound.new("Source absent", code: "not_found"))
  end

  def test_missing_events_consume_stop_as_a_known_refusal
    assert_control_refused("/stop", CybrosAgent::Api::NotFound.new("Source absent", code: "not_found"))
  end

  def test_forbidden_events_consume_steer_without_replaying_or_blocking_later_updates
    assert_control_refused("/steer keep the original goal", CybrosAgent::Api::Forbidden.new("Source refused", code: "forbidden"))
  end

  def test_missing_events_retire_a_previously_cached_history_page
    assert_cached_history_retired(CybrosAgent::Api::NotFound.new("Source absent", code: "not_found"))
  end

  def test_forbidden_events_retire_a_previously_cached_history_page
    assert_cached_history_retired(CybrosAgent::Api::Forbidden.new("Source refused", code: "forbidden"))
  end

  def test_rate_limit_and_server_failures_preserve_the_original_steer_for_retry
    @runtime.consume(telegram_message(1, "start"))
    update = telegram_message(2, "/steer original task", reply_to: 1, reply_user: 1)
    [[CybrosAgent::Api::RateLimited.new(retry_after: 5), 429],
      [CybrosAgent::Api::ServerError.new("Temporary failure", code: "unavailable"), 502]].each do |error, status|
      @event_source[:error] = error
      refusal = assert_raises(Rho::Core::Refused) { @runtime.consume(update) }
      assert_equal status, refusal.status
      assert_equal 2, @state.read.fetch("offset")
      assert_equal update, @state.read.fetch("pending_update").fetch("update")
      assert_equal 1, @bridge.inputs.length
    end
    @event_source.delete(:error)
    @runtime.consume(update)

    assert_nil @state.read["pending_update"]
    assert_equal 3, @state.read.fetch("offset")
    assert_equal "loop-1", @bridge.inputs.fetch("telegram:42:2:input").fetch(:expected_steering_loop_public_id)
  end

  def test_temporary_events_failure_preserves_cached_history_until_recovery
    @runtime.consume(telegram_message(1, "start"))
    @bridge.turn_rows["conversation-1"] = [turn(0, "Recovered answer")]
    [CybrosAgent::Api::RateLimited.new(retry_after: 5), CybrosAgent::Api::ServerError.new("Temporary failure")].each do |error|
      @event_source[:error] = error
      @runtime.tick
      @now += 5
      assert @state.read.fetch("routes").fetch("1:0").fetch("conversations").key?("conversation-1")
      refute @state.read.fetch("deliveries").key?("unavailable:conversation-1")
      refute @client.calls.any? { |_, fields| fields[:text] == "Recovered answer" }
    end
    @event_source.delete(:error)
    @runtime.tick

    assert @client.calls.any? { |_, fields| fields[:text] == "Recovered answer" }
  end

  def test_unexpected_and_transport_exceptions_are_not_converted_to_business_refusals
    [RuntimeError.new("Unexpected event failure"), CybrosAgent::TransportError.new("Connection lost")].each do |error|
      @event_source[:error] = error
      actual = assert_raises(error.class) { @bridge.events("conversation-1", workspace_public_id: "workspace-home") }
      assert_same error, actual
    end
  end

  private

    def assert_control_refused(command, error)
      @runtime.consume(telegram_message(1, "start"))
      @event_source[:error] = error
      update = telegram_message(2, command, reply_to: 1, reply_user: 1)
      @runtime.consume(update)
      @runtime.consume(update)

      document = @state.read
      assert_nil document["pending_update"]
      assert_equal 3, document.fetch("offset")
      assert_includes document.fetch("deliveries").fetch("control:2").fetch("text"), "Request not accepted"
      assert_equal 1, @bridge.inputs.length
      assert_empty @bridge.stops
      @runtime.consume(telegram_message(3, "/new"))
      @runtime.consume(telegram_message(4, "Later request"))
      assert_equal "conversation-2", @bridge.inputs.fetch("telegram:42:4:input").fetch(:conversation_id)
    end

    def assert_cached_history_retired(error)
      @runtime.consume(telegram_message(1, "start"))
      @bridge.turn_rows["conversation-1"] = [turn(0, "Unavailable answer")]
      turns = @bridge.method(:turns)
      reads = []
      @bridge.define_singleton_method(:turns) { |id, **fields| reads << id; turns.call(id, **fields) }
      @event_source[:error] = CybrosAgent::Api::RateLimited.new(retry_after: 5)
      @runtime.tick
      @event_source[:error] = error
      @now += 5
      @runtime.tick

      assert_equal ["conversation-1"], reads
      assert_empty @state.read.fetch("routes").fetch("1:0").fetch("conversations")
      assert @state.read.fetch("deliveries").key?("unavailable:conversation-1")
      refute @client.calls.any? { |_, fields| fields[:text] == "Unavailable answer" }
      assert_equal 1, @bridge.opened.length
    end
end
