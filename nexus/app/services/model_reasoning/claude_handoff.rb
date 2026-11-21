module ModelReasoning
  # A model-bound block stays in its original position even when the next
  # Claude model cannot read it. Deliver its display summary with the new
  # input at that switch. Reconstruct earlier handoffs for the model that
  # actually answered each turn, so switching back preserves signed prefixes.
  class ClaudeHandoff
    def self.rank(provider_id, model_id)
      PortableSummary::CLAUDE_BINDING_ORDER.index(model_id) if provider_id == "anthropic"
    end

    # Existing direct Fable 5 and 5.1 turns can still occur in stored
    # history. Among the four current recipients only Fable 5.2 reads them.
    def self.producer_rank(provider_id, model_id)
      if provider_id == "anthropic" && %w[claude-fable-5 claude-fable-5-1].include?(model_id)
        return rank(provider_id, "claude-fable-5-2")
      end
      rank(provider_id, model_id)
    end

    def self.project(elements, profile:, enabled:, &block)
      return elements if enabled == false || profile.adapter_profile != "anthropic_messages"
      return elements unless elements in Array

      target = rank(profile.provider_id, profile.model_pin)
      target ? new(target).apply(elements, &block) : elements
    end

    def initialize(target)
      @target = target
      @pending = []
      @highest = -1
    end

    def apply(elements)
      output = []
      elements.chunk { |element| assistant?(element) }.each do |assistant, group|
        if assistant
          origin = group.lazy.filter_map { |element| reply_origin(element) }.first
          append_summaries(output, self.class.rank(origin["provider_id"], origin["model_id"])) if origin
          group.each { |element| remember(element) }
        end
        output.concat(group)
      end
      if elements.any? && !assistant?(elements.last)
        note = append_summaries(output, @target)
        yield(note.parts.map(&:text)) if note && block_given?
      end
      output
    end

    private

      def assistant?(element)
        case element
        when Nexus::TextInputMessage then element.role == "assistant"
        when Nexus::ToolCallInputItem, Nexus::ReasoningInputItem then true
        else false
        end
      end

      def reply_origin(element)
        return element.native_origin if element.native_origin

        if element in Nexus::TextInputMessage
          element.parts.find { |part| part.type == Nexus::InputParts::REASONING }&.native_origin
        end
      end

      def remember(element)
        return unless element in Nexus::TextInputMessage

        element.parts.each do |part|
          next unless part.type == Nexus::InputParts::REASONING && part.payload["type"] == "thinking"
          origin = part.native_origin
          next unless origin && origin["api_format"] == "anthropic_messages"

          producer = self.class.producer_rank(origin["provider_id"], origin["model_id"])
          text = part.payload["thinking"]
          next unless producer && text.present?

          @pending << [producer, text]
          @highest = [producer, @highest].max
        end
      end

      def append_summaries(output, recipient)
        return unless recipient && @highest > recipient

        unreadable, @pending = @pending.partition { |producer, _| producer > recipient }
        @highest = @pending.map(&:first).max || -1
        parts = unreadable.map do |_producer, text|
          Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: PortableSummary.labeled(text))
        end
        # Adjacent user blocks coalesce on the Messages wire, after all
        # tool_result blocks. The assistant turn returned by Claude stays exact.
        note = Nexus::TextInputMessage.new(role: "user", parts: parts)
        # A mid-conversation system update must remain the last entry
        # before the assistant. Add the note to its preceding user turn.
        if output.last in Nexus::TextInputMessage(role: "system")
          output.insert(-2, note)
        else
          output << note
        end
        note
      end
  end
end
