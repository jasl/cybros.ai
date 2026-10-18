require "cybros_agent/realtime"

module CybrosAgentTest
  # THE SOCKET AN OPENER TALKS TO, scripted: a real `Realtime::Client` whose
  # handshake is a no-op and whose `subscribe` records the channel and
  # params it was opened with and answers a real `Realtime::Subscription`
  # pre-filled with a fixed list of frames, then ended — so a context's
  # opener can be pinned on what it subscribes to and what it projects
  # without a cable, under the same signatures the shipped client keeps.
  class FakeRealtimeClient < CybrosAgent::Realtime::Client
    Opened = Struct.new(:channel, :params)

    attr_reader :subscriptions

    def initialize(frames = [])
      super(endpoint: CybrosAgent::Realtime::Endpoint.new(
        base_url: "http://kernel.test", credential: "sk-member"
      ))
      @frames = frames
      @subscriptions = []
    end

    def connect_for_feed(welcome_timeout: nil) = self

    def subscribe(channel:, params: {}, timeout: nil)
      @subscriptions << Opened.new(channel, params)
      CybrosAgent::Realtime::Subscription.new(
        client: self, identifier: channel, wire_identifier: channel
      ).tap do |subscription|
        @frames.each { |frame| subscription.deliver(frame) }
        subscription.finish
      end
    end

    def unsubscribe(_subscription) = nil
  end
end
