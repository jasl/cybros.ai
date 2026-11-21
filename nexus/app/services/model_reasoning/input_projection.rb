module ModelReasoning
  # The neutral items this recipient can read. The request compiler and its
  # estimate use this same projection of the immutable sealed input.
  class InputProjection
    def self.call(input, profile:, enabled:)
      return input unless profile.workload == "text_generation" && (input in Array)

      new(profile, enabled).call(input)
    end

    def initialize(profile, enabled)
      @profile = profile
      @enabled = enabled
    end

    def call(input)
      input = ClaudeHandoff.project(input, profile: @profile, enabled: @enabled)
      preceding_summary = false
      input.each_with_object([]) do |element, projected|
        item = project_element(element)
        next unless item

        # Keep a portable item-level summary on the next unlabelled
        # assistant message so strict chat wires see one calling message.
        if preceding_summary && (item in Nexus::TextInputMessage(role: "assistant", phase: nil))
          item = item.with(parts: projected.pop.parts + item.parts)
        end
        projected << item
        preceding_summary = (element in Nexus::ReasoningInputItem) && (item in Nexus::TextInputMessage)
      end
    end

    private

      def project_element(element)
        case element
        when Nexus::ReasoningInputItem
          item = reasoning(element)
          return item unless item in Nexus::TextInputPart

          Nexus::TextInputMessage.new(role: "assistant", parts: [item])
        when Nexus::TextInputMessage
          parts = element.parts.filter_map { |part| project_part(part) }
          return if parts.empty?

          phase = element.phase if lane?(element.native_origin)
          element.with(parts: parts, phase: phase)
        when Nexus::ToolCallInputItem
          return element unless element.payload.key?("provider_payload") && element.native_origin
          return element if gemini_signature?(element.native_origin)

          element.with(payload: element.payload.except("provider_payload"), native_origin: nil)
        else element
        end
      end

      def project_part(part)
        case part.type
        when Nexus::InputParts::REASONING then reasoning(part)
        when Nexus::InputParts::TEXT
          return part unless part.native_origin
          return part if part.thought_signature && gemini_signature?(part.native_origin)

          part.with(thought_signature: nil, native_origin: nil) unless part.text.empty?
        else part
        end
      end

      def reasoning(item)
        origin = item.native_origin
        return item unless origin

        if matches?(origin)
          payload = item.payload
          return item unless payload["type"] == "thought" && payload["thoughtSignature"] && !gemini_signature?(origin)

          return item.with(payload: payload.except("thoughtSignature")) if payload["text"].present?
          return
        end
        return if origin["model_id"] == @profile.model_pin && origin["provider_id"] == @profile.provider_id

        text = PortableSummary.from_payload(item.payload, origin: origin)
        Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: text) if text
      end

      def lane?(origin)
        origin && origin["api_format"] == @profile.adapter_profile && origin["provider_id"] == @profile.provider_id
      end

      def matches?(origin)
        lane?(origin) && ReplayLadder.origin_miss(origin: origin, provider_id: @profile.provider_id,
          model_id: @profile.model_pin, reasoning_enabled: @enabled,
          format: TraceBuilder::ORIGIN_FORMAT_VARIANTS[origin["api_format"]]).nil?
      end

      def gemini_signature?(origin)
        matches?(origin) && ReplayLadder.gemini_signatures?(origin["model_id"], @profile.model_pin)
      end
  end
end
