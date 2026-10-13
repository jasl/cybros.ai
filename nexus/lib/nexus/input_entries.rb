module Nexus
  # One entry per message: a loop re-sends its prefix every turn, and flattening
  # would make stored bytes quadratic. The inverse lives here too, because a
  # decomposition and its reassembly are one contract.
  class InputEntries
    class << self
      def for(value)
        case value
        when Array then value.map { |element| entry(element) }
        when nil then []
        else [entry(value)]
        end
      end

      # Image edits have an ordered list of source-image occurrences beside
      # their prompt. The body-upload join keeps bytes alive, not their order.
      def for_image(prompt, upload_public_ids:)
        entries = self.for(prompt)
        if upload_public_ids.any?
          parts = upload_public_ids.map do |public_id|
            UploadInputPart.new(type: InputParts::UPLOAD, upload_public_id: public_id)
          end
          entries << TextInputMessage.new(role: "user", parts: parts).to_h
        end
        entries
      end

      # The workload restores what `for` erased: a single text payload was
      # a lone string or a one-element embedding list.
      def from(entries:, workload:)
        case workload
        when "text_generation" then text_input(entries)
        when "embedding" then entries.map { |payload| payload.fetch("text") }
        when "image_generation" then entries.first.fetch("text")
        when "speech_generation" then entries.sole.fetch("text")
        # The only workload whose text is optional: the audio rides as the
        # single bound upload, and an absent prompt is a real answer.
        when "transcription" then entries.first&.fetch("text")
        else raise ArgumentError, "unhandled workload: #{workload}"
        end
      end

      private

        def entry(element)
          case element
          when Nexus::TextInputMessage then element.to_h
          when Nexus::ReasoningInputItem then element.to_h
          when Nexus::ToolCallInputItem then element.to_h
          when Nexus::ToolResultInputItem then element.to_h
          when String then { "text" => element }
          else raise ArgumentError, "undecomposable input element: #{element.class}"
          end
        end

        def text_input(entries)
          structured = entries.any? do |payload|
            payload.key?("parts") ||
              %w[reasoning_item tool_call_item tool_result_item].include?(payload["type"])
          end
          return entries.sole.fetch("text") unless structured

          entries.map do |payload|
            case payload["type"]
            when "reasoning_item" then Nexus::ReasoningInputItem.from_h(payload)
            when "tool_call_item" then Nexus::ToolCallInputItem.from_h(payload)
            when "tool_result_item" then Nexus::ToolResultInputItem.from_h(payload)
            else Nexus::TextInputMessage.from_h(payload)
            end
          end
        end
    end
  end
end
