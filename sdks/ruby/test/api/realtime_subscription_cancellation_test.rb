require "test_helper"
require "cybros_agent/realtime"
require_relative "../support/fake_cable_server"

class RealtimeSubscriptionCancellationTest < Minitest::Test
  CHANNEL = "AgentAPI::V1::RunEventsChannel".freeze

  def test_canceling_before_confirmation_frees_only_that_subscription_and_ignores_late_frames
    Async do |scope|
      commands = []
      subscribed = []
      pending_seen = Thread::Queue.new
      server = CybrosAgentTest::FakeCableServer.new do |session|
        session.welcome
        while (command = session.read_command)
          commands << command
          next unless command.fetch("command") == "subscribe"

          identifier = command.fetch("identifier")
          subscribed << identifier
          case subscribed.length
          when 1
            session.confirm(identifier)
          when 2
            pending_seen << true
          when 3
            session.confirm(subscribed.fetch(1))
            session.broadcast(subscribed.fetch(1), { "stale" => true })
            session.reject(subscribed.fetch(1))
            session.confirm(identifier)
            session.broadcast(identifier, { "fresh" => true })
            session.broadcast(subscribed.fetch(0), { "still_live" => true })
          else
            raise "unexpected subscription"
          end
        end
      end.start(scope)
      client = CybrosAgent::Realtime::Client.new(endpoint: CybrosAgent::Realtime::Endpoint.new(
        base_url: server.base_url, credential: "synthetic-member"))

      scope.with_timeout(2) do
        client.connect
        stable = client.subscribe(channel: CHANNEL, params: { run_id: "stable" })
        pending = scope.async { client.subscribe(channel: CHANNEL, params: { run_id: "waited" }) }
        pending_seen.pop
        pending.stop

        assert_predicate client, :connected?
        assert_includes client.inspect, "subscriptions=1"
        replacement = client.subscribe(channel: CHANNEL, params: { run_id: "waited" })
        assert_equal({ "fresh" => true }, replacement.pop(timeout: 1))
        assert_equal({ "still_live" => true }, stable.pop(timeout: 1))
        refute_equal subscribed.fetch(1), replacement.wire_identifier
        assert_equal %w[subscribe subscribe unsubscribe subscribe], commands.map { |command| command.fetch("command") }
        assert_equal subscribed.fetch(1), commands.fetch(2).fetch("identifier")
      end
    ensure
      client&.close
      server&.stop
    end.wait
  end
end
