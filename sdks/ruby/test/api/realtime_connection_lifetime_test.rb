require "test_helper"
require "cybros_agent/realtime"
require_relative "../support/fake_cable_server"

class RealtimeConnectionLifetimeTest < Minitest::Test
  def test_canceling_the_first_subscriber_preserves_the_shared_connection
    Async do |scope|
      server = CybrosAgentTest::FakeCableServer.new do |session|
        session.welcome
        while (command = session.read_command)
          next unless command.fetch("command") == "subscribe"

          session.confirm(command.fetch("identifier"))
          session.broadcast(command.fetch("identifier"), { "received" => true })
        end
      end.start(scope)
      client = CybrosAgent::Realtime::Client.new(endpoint: CybrosAgent::Realtime::Endpoint.new(
        base_url: server.base_url, credential: "synthetic-member"))
      connected = Thread::Queue.new
      first = scope.async do
        client.connect_for_feed
        connected << true
        sleep 10
      end
      connected.pop
      first.stop
      scope.with_timeout(1) do
        subscription = client.subscribe(channel: "AgentAPI::V1::RunEventsChannel", params: { run_id: "second" })
        assert_equal({ "received" => true }, subscription.pop)
        subscription.unsubscribe
      end
    ensure
      client&.close
      server&.stop
    end.wait
  end
end
