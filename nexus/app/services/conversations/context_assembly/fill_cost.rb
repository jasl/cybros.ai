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
      # items trailing it, each native attachment at the wire's declared cost,
      # and the reasoning the ladder landed on it — or a tool-heavy,
      # picture-bearing or thinking turn is under-funded and history
      # over-fills.
      def segment(segment, profile)
        segment.priced_texts.sum { |text| call(text, profile) } +
          segment.attachments.sum { |part| attachment(profile, part.upload.content_type) } + segment.replay_tokens
      end

      # Charge the fact for this attachment's actual MIME type. PDF's
      # unknown cost never borrows an image's fixed cost.
      # Unknown media estimates contribute 0 here; observed provider usage
      # arrives one round later and the usage gate takes over.
      def attachment(profile, content_type)
        return 0 if profile.nil?

        _modality, facts = profile.input_media.find { |_name, media| media.mime_allowlist.include?(content_type) }
        facts&.token_cost.to_i
      end
    end
  end
end
