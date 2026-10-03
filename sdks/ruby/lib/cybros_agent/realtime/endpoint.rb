require "uri"

module CybrosAgent
  module Realtime
    # WHERE THE CABLE IS AND WHAT TO PRESENT TO IT. Pure derivation, no IO —
    # pair it with any WebSocket client, or hand it to the Client here.
    #
    # THE CREDENTIAL IS ASKED FOR FRESH ON EVERY CALL, which is the whole
    # reason this takes a callable and not a String. A WebSocket handshake
    # pins the bearer it presented for the life of the connection, so the only
    # moment a rotated credential can be picked up is the next connect — and
    # that only works if the source is consulted then rather than captured
    # once at construction.
    class Endpoint
      # The versioned agent API's own realtime address, not Rails' single-app
      # default. Held here so the gem, the harness and the docs cannot drift.
      CABLE_PATH = "/agent_api/v1/cable".freeze

      # The subprotocols ActionCable speaks. The second is the "I don't
      # understand you" marker the server answers with when the first is not
      # acceptable, which is how a version mismatch becomes visible rather
      # than a silent stall.
      PROTOCOLS = %w[actioncable-v1-json actioncable-unsupported].freeze

      def initialize(base_url:, credential:, cable_path: CABLE_PATH)
        @base_url = base_url
        @credential = credential
        @cable_path = cable_path
      end

      def url
        uri = URI.join(@base_url, @cable_path)
        uri.scheme = uri.scheme == "https" ? "wss" : "ws"
        uri.to_s
      end

      def headers
        {
          "Authorization" => "Bearer #{bearer}",
          # Sent even though Nexus admits an origin-less upgrade, because the
          # day a deployment narrows `allowed_request_origins` an origin-less
          # client is refused at the server layer with no diagnosis at all.
          "Origin" => origin,
          "Sec-WebSocket-Protocol" => PROTOCOLS.join(", "),
        }
      end

      private

        def bearer
          value = @credential.respond_to?(:call) ? @credential.call : @credential
          raise ArgumentError, "the credential source answered nothing" if value.to_s.empty?

          value
        end

        # A default port is elided, because an Origin carrying one does not
        # match the same-origin form a server compares against.
        def origin
          uri = URI.parse(@base_url)
          default = (uri.scheme == "http" && uri.port == 80) ||
            (uri.scheme == "https" && uri.port == 443)

          "#{uri.scheme}://#{uri.host}#{default ? nil : ":#{uri.port}"}"
        end
    end
  end
end
