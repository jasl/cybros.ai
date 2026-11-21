module ModelReasoning
  # Only material the originating protocol identifies as a display summary
  # can become ordinary assistant history on a different model.
  module PortableSummary
    # These catalogued Messages models expose display summaries in thinking
    # blocks. A custom endpoint serving full reasoning has no such contract.
    # On the Claude API each of these four reads its own blocks and those
    # to its left. Unknown model pairs stay under the API's native rules.
    # https://platform.claude.com/docs/en/build-with-claude/preserved-thinking
    CLAUDE_BINDING_ORDER = %w[claude-haiku-5-5 claude-sonnet-5-5 claude-opus-5-5 claude-fable-5-2].freeze
    # Earlier direct models can still own a captured conversation.
    SUMMARIZED_CLAUDE = (CLAUDE_BINDING_ORDER + %w[claude-fable-5 claude-fable-5-1 claude-sonnet-5]).freeze

    module_function

    def from_trace(trace)
      trace.reasoning_items.filter_map do |item|
        next if item["redacted"]

        text = item["summary_text"]
        if trace.origin_format_variant == "gemini_thought"
          text ||= item["text"]
        elsif trace.origin_format_variant == "anthropic_thinking" && summarized_claude?(trace.origin_provider_id, trace.origin_model_id)
          text ||= item.dig("provider_payload", "thinking") || item["text"]
        end
        labeled(text)
      end
    end

    # A previously sealed native item can cross the same boundary later.
    # Reasoning text from chat/DeepSeek and opaque fields have no summary.
    def from_payload(payload, origin:)
      text = case payload["type"]
      when "thought" then payload["text"]
      when "thinking"
        payload["thinking"] if origin["api_format"] == "anthropic_messages" &&
          summarized_claude?(origin["provider_id"], origin["model_id"])
      when "reasoning"
        Array(payload["summary"]).filter_map { |part| part["text"] if part["type"] == "summary_text" }.join
      when "reasoning_details"
        Array(payload["blocks"]).filter_map do |block|
          block["summary"] || block["text"] if block["type"] == "reasoning.summary"
        end.join("\n\n")
      else nil
      end
      labeled(text)
    end

    def summarized_claude?(provider, model)
      provider == "anthropic" && SUMMARIZED_CLAUDE.include?(model)
    end

    def labeled(text)
      "Prior model's reasoning summary:\n#{text}" if text.present?
    end
  end
end
