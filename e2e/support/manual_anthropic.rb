require_relative "manual_client"

module E2E
  # The Anthropic half of the manual-provider lane, for the ONE thing a
  # mock cannot show: whether a real provider actually read the prefix
  # the kernel marked. Same gating as the OpenAI smoke — paid, local,
  # opt-in.
  module ManualAnthropic
    # A THINKING model of the Claude 5 family (the catalog's
    # `20_anthropic.yml` rows: adaptive thinking, `anthropic_thinking`
    # replay) — the cache probe replays its own reasoning across a tool
    # loop, the case the kernel's tail marker was skipped on (the cache
    # audit of 2026-09-16, prefix-1); the cheapest of the three.
    DEFAULT_MODEL = "claude-sonnet-5".freeze
    # Anthropic's minimum cacheable prefix is model-class-dependent
    # (1024/2048/4096 tokens); under it nothing caches at all — silently,
    # with no charge and no benefit. The probe's corpus must clear the
    # largest of them on its own or it proves nothing.

    # The probes that DECLARE TOOLS need the lane to admit them; the
    # cache probe needed the marker to be legal. Both are properties
    # of the real model, and a manual profile that understates them
    # refuses the request before any provider ever sees it.
    CAPABILITIES = %w[streaming tool_calls prompt_caching reasoning].freeze
    # A three-round tool loop on a thinking model; each round is one answer.
    TIMEOUT_SECONDS = 120

    module_function

    # This paid lane requires both explicit opt-in and a direct Anthropic key; broker credentials do
    # not substitute for the provider connection being measured.
    def live?(env = ENV) = env["E2E_LIVE"] == "1" && !env[lane.key_name].to_s.strip.empty?

    def lane = ProviderLanes.lane("anthropic")

    def validate!(env = ENV) = ManualClient.validate!(env)

    def model(env = ENV)
      env["E2E_LIVE_ANTHROPIC_MODEL"].to_s.strip.then do |value|
        value.empty? ? DEFAULT_MODEL : value
      end
    end

    def client(env = ENV)
      ManualClient.client(lane: lane, model: model(env), env: env, timeout: TIMEOUT_SECONDS, capabilities: CAPABILITIES)
    end

    # A corpus that is UNIQUE PER RUN. Anthropic's cache is org-scoped
    # with a 5-minute TTL, so an unsalted corpus left warm by an earlier
    # run turns the writes this probe expects into reads — observed live
    # by the predecessor, and the reason salting is not optional.
    def corpus(salt)
      line = "Reference item %04d for run #{salt}: the quick brown fox " \
             "jumps over the lazy dog and files a report.\n"
      # ~12 tokens a line; 600 lines clears the largest minimum prefix
      # with room to spare.
      (1..600).map { |n| format(line, n) }.join
    end
  end
end
