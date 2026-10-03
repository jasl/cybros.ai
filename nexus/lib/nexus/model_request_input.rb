module Nexus
  # The database-independent value the one model-request compiler consumes:
  # semantic members from the Invocation's sealed request, wire members from the
  # catalog profile selected for this send. Never persisted.
  ModelRequestInput = Data.define(
    :profile_id,
    :adapter_profile,
    :protocol_route,
    :workload,
    :wire_model,
    # The normalized semantic content, occurrences included. Media parts still
    # name their Upload; resolving each occurrence to bytes belongs to compile.
    :input,
    # Provider-neutral controls exactly as acceptance normalized them. Wire
    # names live one layer down in ModelRequests::WireLowering.
    :generation_config,
    :reasoning_effort,
    :stream
  ) do
    class << self
      # The ordered text carried by one normalized request. Media remains
      # under its byte limits; tokenizing its encoded bytes would not estimate
      # the Provider's multimodal accounting.
      def text_segments(input)
        case input
        when Array then input.flat_map { |element| element_segments(element) }
        when String then [input]
        when nil then []
        else raise ArgumentError, "unhandled model request input: #{input.class}"
        end
      end

      private

        def element_segments(element)
          case element
          when String then [element]
          when TextInputMessage
            element.parts.flat_map { |part| part_segments(part) }
          when ReasoningInputItem
            # The summary and plain-text content are countable here; an
            # encrypted blob's cost is the provider's captured accounting,
            # not tokenizable.
            (Array(element.payload["summary"]) + Array(element.payload["content"])).filter_map { |part| part["text"] }
          when ToolCallInputItem
            [element.payload["name"], element.payload["arguments"]].compact
          when ToolResultInputItem
            [element.payload["output"].to_s]
          else raise ArgumentError, "unhandled model request input element: #{element.class}"
          end
        end

        def part_segments(part)
          case part.type
          when InputParts::TEXT then [part.text]
          when InputParts::REASONING
            # A replayed thinking block's text is provider input and counts,
            # so do the chat field's text blocks; opaque data (redacted or
            # encrypted blobs) is not tokenizable here.
            [part.payload["thinking"] || part.payload["text"]].compact +
              Array(part.payload["blocks"]).filter_map { |block| block["text"] }
          else []
          end
        end
    end

    def self.from_invocation(invocation:, profile:, generation_config:, input:, stream: false)
      new(
        profile_id: profile.profile_id,
        adapter_profile: profile.adapter_profile,
        protocol_route: profile.protocol_route,
        workload: profile.workload,
        wire_model: profile.model_pin,
        input: input,
        generation_config: generation_config,
        reasoning_effort: invocation.reasoning_effort,
        stream: stream
      )
    end

    # The ordered text this request carries for the profile/token-count
    # contract. Media stays under its own byte bound; tokenizing base64 would
    # not estimate the provider's multimodal input accounting.
    def text_segments = self.class.text_segments(input)
  end
end
