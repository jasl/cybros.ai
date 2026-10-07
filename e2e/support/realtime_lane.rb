require "cybros_agent/realtime"

module E2E
  # DRIVING THE SHIPPED REALTIME CLIENT the way a consumer must drive it: it
  # is fiber-native, so the socket work runs inside a reactor. That is not a
  # harness detail — it is the usage shape, and a journey that faked it would
  # prove nothing about the thing that ships.
  #
  # Shared because two lanes now subscribe: one against a fake provider, for
  # the protocol, and one against a real one, for the cadence.
  module RealtimeLane
    def with_reactor(&block)
      Sync do
        block.call
      ensure
        # THE CLIENT MUST BE CLOSED, and not only for tidiness: its frame pump
        # is an ordinary child task, so a reactor block that does not close it
        # waits on a pump that runs until the socket does — which is a hang,
        # not a leak. Closing is what ends the pump and lets the reactor
        # unwind.
        @client&.close
        @client = nil
      end
    end

    # THE NONCE RIDES ALONG. `Protocol.wire_identifier` injects an SDK-owned
    # field so a resubscribe cannot be confused with its predecessor, and it
    # only works if the server passes an unknown param through — which this
    # subscribe proves against the real channel every time it is confirmed.
    def subscribe_to(inference_request_public_id)
      endpoint = CybrosAgent::Realtime::Endpoint.new(
        base_url: @base_url, credential: @actor.member_token
      )
      @client = CybrosAgent::Realtime::Client.new(endpoint: endpoint)
      @client.connect
      @client.subscribe(
        channel: "AgentAPI::V1::InferenceRequestEventsChannel",
        params: { workspace_id: @workspace.public_id, inference_request_id: inference_request_public_id }
      )
    end

    # THE TRANSCRIPT STREAM on a conversation: the same channel as the feed, `items: "transcript"`,
    # read as the member who owns the work. Shared by the direct-reply lane and the rho journey,
    # whose loop-backed rounds settle on this stream through the seam.
    def subscribe_to_transcript(conversation_public_id, workspace_public_id: @workspace.public_id,
                                credential: @actor.member_token)
      endpoint = CybrosAgent::Realtime::Endpoint.new(base_url: @base_url, credential: credential)
      @client = CybrosAgent::Realtime::Client.new(endpoint: endpoint)
      @client.connect
      @client.subscribe(
        channel: "AgentAPI::V1::ConversationEventsChannel",
        params: {
          workspace_id: workspace_public_id,
          conversation_id: conversation_public_id,
          items: "transcript",
        }
      )
    end

    # "Nothing more arrived" is a real end condition for a phase whose producer
    # has no closing item to send, and a timeout is how the shipped API says it.
    def drain_until_quiet(subscription, idle:)
      seen = []
      loop do
        message = subscription.pop(timeout: idle)
        break if message.nil?

        seen << message.fetch("event")
      end
      seen
    rescue CybrosAgent::Realtime::TimeoutError
      seen
    end

    def drain_until(subscription, type, timeout:)
      seen = []
      loop do
        message = subscription.pop(timeout: timeout)
        break if message.nil?

        seen << message.fetch("event")
        break if seen.last.fetch("type") == type
      end
      seen
    end
  end
end
