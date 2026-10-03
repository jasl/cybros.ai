module E2E
  # THE OUTPUT CAP IS PER MODEL, one table for both benches. A thinking
  # model spends its budget before the call: on the cross-model run
  # glm-5.3 spent a flat 4096 thinking and six of twelve O4 samples read
  # as "no compose, finish length" (measured); on the task lane's first
  # style run the same flat cap left glm-5.3's T2 as an empty message
  # five times in nine, with nothing recorded to say why. The rest keep
  # the flat cap — a model named by exact id only, so a new thinking model
  # lands there until it is listed — and `E2E_BENCH_MAX_OUTPUT_TOKENS`
  # sets one cap for a whole run. Every sample records the cap it ran
  # under beside the provider's finish, so an exhausted cap is read as the
  # cap and never as a choice. The stronger tier is glm-5.3 and kimi-k3.
  module OutputCaps
    DEFAULT = 4096
    # The direct frontier lanes are keyed by their wire ids; OpenAI's
    # reasoning guide asks for at least 25,000 tokens of room for reasoning
    # plus output, and Opus 5.5's adaptive thinking counts against its
    # max_tokens. Grok 4.7 states no output limit, reasons on every call
    # ("Reasoning cannot be disabled", xAI's reasoning guide) and counts
    # that reasoning in `max_output_tokens` (xAI's Responses reference,
    # read 2026-09-27), so it takes the same room.
    BY_MODEL = {
      "z-ai/glm-5.3" => 16_384,
      "moonshotai/kimi-k3" => 16_384,
      "claude-opus-5-5" => 32_768,
      "gpt-6.1-sol" => 32_768,
      "gpt-6-luna" => 32_768,
      "grok-4.7" => 32_768,
    }.freeze

    def self.for(model, env = ENV)
      override = env["E2E_BENCH_MAX_OUTPUT_TOKENS"].to_s
      override.empty? ? BY_MODEL.fetch(model, DEFAULT) : Integer(override)
    end
  end
end
