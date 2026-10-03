module Conversations
  class ContextAssembly
    # How assembly charges text when deciding what rides: an exact counter
    # speaks tokens, else bytes/4 — an upper bound is right for a gate and
    # wrong for filling, where it would waste three quarters of the window.
    module FillCost
      module_function

      def call(text, profile)
        return 0 if text.blank?

        if profile
          counted = ModelRequests::TokenCount.count(profile: profile, segments: [text])
          return counted.tokens if counted.counted? && counted.exact?
        end

        (text.bytesize / 4.0).ceil
      end

      # A segment is priced as the wire sends it: its message, the tool
      # items trailing it, each native picture at the wire's declared cost,
      # and the reasoning the ladder landed on it — or a tool-heavy,
      # picture-bearing or thinking turn is under-funded and history
      # over-fills.
      def segment(segment, profile)
        segment.priced_texts.sum { |text| call(text, profile) } +
          segment.attachments.length * attachment(profile) + segment.replay_tokens
      end

      # What ONE native image part costs on this wire: the register's own
      # per-image figure (`input_media.image.token_cost`, declared by the
      # Anthropic, OpenAI and Gemini wires), 0 where the register says the
      # host's accounting is not knowable — the provider's `input_tokens`
      # arrives one round later and the usage gate takes over.
      def attachment(profile)
        return 0 if profile.nil?

        profile.input_media["image"]&.token_cost.to_i
      end
    end
  end
end
