require_relative "openai_responses"

module SimpleInference
  module Protocols
    # DeepSeek native Responses API protocol: POST /responses (no /v1 prefix).
    # The provider's pricing page lists two ids on this route —
    # `deepseek-flash` and `deepseek-v4-pro` (read 2026-09-16; the 2026-08-09
    # ruling had put the flash model here alone, and the mandate of
    # 2026-09-16 adds the pro row).
    #
    # Register-frozen probe facts this file conforms to
    # (`deepseek_responses.usage.v1` + the DeepSeek reasoning-contract row,
    # probed 2026-08-09):
    #
    # - SSE taxonomy matches the OpenAI Responses family (response.created …
    #   response.reasoning_text.delta … response.completed, with
    #   response.incomplete/response.failed as the other documented
    #   terminals), so the OpenAIResponses parsing engine is reused verbatim.
    #   Usage rides the terminal response.completed event only.
    # - reasoning.effort is a verbatim closed 7-value set
    #   none|minimal|low|medium|high|xhigh|max. "none" disables thinking;
    #   there is NO thinking.type toggle on this route. No clamping, no
    #   mapping; an out-of-set value is a loud local rejection with zero
    #   outbound IO.
    # - Statelessness is structural: store, previous_response_id,
    #   conversation, parallel_tool_calls (and friends) are silently ignored
    #   by the wire. Nexus never sends a control whose effect it cannot
    #   observe, so none of them is in this lane's request vocabulary.
    # - reasoning.summary is accepted but never generated, and
    #   reasoning.encrypted_content is unsupported — reasoning arrives as
    #   plaintext response.reasoning_text items. The OpenAI stateless-CoT
    #   capture defaults (store:false + include) must therefore NOT be
    #   applied here.
    # - Text-only lane: no media input exists on this route.
    class DeepSeekResponses < OpenAIResponses
      DEFAULT_RESPONSES_PATH = "/responses".freeze

      # Probe-frozen closed set; a bogus value is rejected upstream
      # enumerating exactly these seven variants, and the same set is
      # enforced locally before any IO. This is the WIRE GATE — the deepseek
      # registry rows' `reasoning_options` efforts are the other fact with
      # the other job (the reviewed per-lane catalog subset offered at
      # selection), which may narrow this set but never exceed it (pinned
      # by test_reasoning_wire_gates).
      REASONING_EFFORTS = %w[none minimal low medium high xhigh max].freeze

      # The closed lane vocabulary. Relative to the OpenAI archetype it drops
      # every structurally-ignored stateless control (store,
      # previous_response_id, conversation, parallel_tool_calls, include) and
      # the never-generated reasoning_summary; anything outside this list is
      # a loud local rejection pointing at extra_body.
      def self.request_option_keys
        %i[
          model input stream
          instructions
          tools tool_choice
          response_format text
          reasoning reasoning_effort
          max_output_tokens temperature top_p
        ].freeze
      end

      def initialize(responses_path: nil, **connection)
        configured = responses_path.to_s.strip
        super(responses_path: configured.empty? ? DEFAULT_RESPONSES_PATH : configured, **connection)
      end

      private

      # Wire lowering IS the OpenAI Responses archetype (inherited
      # responses_request_options) minus every OpenAI-only default, expressed
      # through the parent's two seams instead of a copied method (fix 4):

      # reasoning.summary is accepted but never generated on this route, so
      # no summary default is ever synthesized.
      def reasoning_summary_default
        nil
      end

      # The OpenAI stateless-CoT capture defaults (store:false + the
      # encrypted-reasoning include) must NOT be applied here: reasoning
      # arrives as plaintext response.reasoning_text items and
      # encrypted_content is unsupported.
      def reasoning_capture_defaults?
        false
      end

      def validate_reasoning_options(reasoning)
        return if reasoning.nil?

        unknown = reasoning.keys.map(&:to_sym) - [:effort]
        unless unknown.empty?
          raise SimpleInference::ValidationError,
                "reasoning option(s) not supported on the DeepSeek Responses route: " \
                "#{unknown.join(", ")} (summary is accepted but never generated and " \
                "encrypted_content is unsupported — only reasoning.effort is selectable)"
        end

        effort = reasoning[:effort]
        return if REASONING_EFFORTS.include?(effort.to_s)

        raise SimpleInference::ValidationError,
              "reasoning.effort #{effort.inspect} is outside the DeepSeek Responses " \
              "closed set (#{REASONING_EFFORTS.join("|")}); values pass through " \
              "verbatim — no clamping or mapping exists on this lane"
      end
    end
  end
end
