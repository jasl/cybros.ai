require "json"
require "securerandom"

module CybrosAgent
  module Realtime
    # The pure ActionCable wire vocabulary: identifier encoding, outgoing
    # command frames, and incoming frame parsing. No IO — fully testable
    # without a socket. Client owns the connection lifecycle; this module owns
    # the bytes-on-the-wire shapes.
    module Protocol
      TYPE_WELCOME = "welcome"
      TYPE_PING = "ping"
      TYPE_CONFIRM = "confirm_subscription"
      TYPE_REJECT = "reject_subscription"
      TYPE_DISCONNECT = "disconnect"
      SDK_SUBSCRIPTION_ID_KEY = "_cybros_sdk_subscription_id"

      module_function

      # Stable logical identity for duplicate detection and the public
      # Subscription handle. The wire form below adds a per-attempt nonce.
      def identifier(channel:, params: {})
        params = canonicalize_hash((params || {}).to_h, path: "params")
        if params.key?("channel")
          raise ArgumentError, "params must not redefine :channel"
        end
        if params.key?(SDK_SUBSCRIPTION_ID_KEY)
          raise ArgumentError, "params must not redefine #{SDK_SUBSCRIPTION_ID_KEY}"
        end

        JSON.generate(canonicalize_hash({ "channel" => channel }.merge(params), path: "identifier"))
      end

      # ActionCable echoes and routes by the COMPLETE RAW IDENTIFIER, so a
      # resubscribe to the same channel with the same params is
      # indistinguishable from its predecessor — and a late frame from the
      # dying one would be routed to its replacement. A fresh SDK-owned field
      # makes consecutive subscriptions distinct.
      #
      # It is a protocol EXTENSION, not a Rails feature: the server echoes the
      # identifier verbatim and a channel reads the params it knows, so an
      # extra one passes through. Nexus's InferenceRequest channel reads only
      # `workspace_id` and `inference_request_id`, which the e2e journey proves by
      # subscribing with the nonce present.
      def wire_identifier(identifier, nonce: SecureRandom.uuid)
        parsed = JSON.parse(identifier)
        parsed[SDK_SUBSCRIPTION_ID_KEY] = nonce.to_s
        JSON.generate(parsed)
      end

      def subscribe_command(identifier)
        JSON.generate({ command: "subscribe", identifier: })
      end

      def unsubscribe_command(identifier)
        JSON.generate({ command: "unsubscribe", identifier: })
      end

      # A channel ACTION: ActionCable's `message` command carries the action
      # and its arguments JSON-encoded inside the frame, as its own client
      # sends them. The executor pong is the one this gem sends.
      def message_command(identifier, data)
        JSON.generate({ command: "message", identifier:, data: JSON.generate(data) })
      end

      # Parse one incoming text frame. Returns the frame Hash, or nil for
      # anything that is not a JSON object (the protocol only speaks objects;
      # unparseable frames are dropped, never raised, so one bad frame cannot
      # kill the pump).
      def parse_frame(text)
        parsed = JSON.parse(text)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      def canonicalize_hash(hash, path:)
        canonical = {}
        hash.each do |key, value|
          string_key = key.to_s
          if canonical.key?(string_key)
            raise ArgumentError, "duplicate key #{string_key.inspect} after stringification at #{path}"
          end

          canonical[string_key] = canonicalize_value(value, path: "#{path}.#{string_key}")
        end
        canonical.sort.to_h
      end

      def canonicalize_value(value, path:)
        case value
        when Hash
          canonicalize_hash(value, path:)
        when Array
          value.each_with_index.map { |item, index| canonicalize_value(item, path: "#{path}[#{index}]") }
        else
          value
        end
      end
      private_class_method :canonicalize_hash, :canonicalize_value
    end
  end
end
