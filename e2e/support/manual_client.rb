require "active_support/core_ext/object/blank"
require "simple_inference"
require_relative "../../nexus/app/services/model_invocations/apply_result"
require_relative "../../nexus/app/services/model_requests/wire_lowering"
require_relative "../../nexus/app/services/usage_records/tokens"
require_relative "../../nexus/lib/nexus/prompt_cache/breakpoints"
require_relative "provider_lanes"

module E2E
  # ONE BUILDER FOR EVERY MANUAL LANE: a paid, local, opt-in call straight to a provider, with no
  # world and no kernel in between — the text benches and the provider probes. The lane
  # (`ProviderLanes`) says which endpoint, wire and key; this builds the execution profile the gem
  # needs from the wire's own defaults, the way the catalog composes one, and nothing here knows a
  # broker from a first party.
  module ManualClient
    # A non-streaming call waits for the whole answer, and the longest recorded text-bench round
    # took 380 s (a thinking model on the broker); the timeout sits above it, so a
    # slow answer is measured rather than cut off as an error.
    TIMEOUT_SECONDS = 420
    # A bench's call declares tools, and prompt caching is every text row's catalog default — the
    # capability `cached` places the kernel's markers by; a probe that needs more (the Anthropic
    # cache probe's replayed reasoning) names its own set.
    CAPABILITIES = %w[streaming tool_calls prompt_caching].freeze
    # THE KERNEL'S TIER FOR ROUNDS NO PERSON PACES: Build gives a standalone loop's rounds, seconds
    # apart, the 5-minute tier (`ModelRequests::Build#cache_tier`); a bench's draws are seconds apart.
    CACHE_TIER = "5m"
    # THE PROVIDER BILLS A RECORDED CALL KEEPS, each under the name its wire gives it: the broker's
    # `cost` and xAI's `cost_in_usd_ticks`. A lane whose native cost contract names another field
    # would need that field added here before benchmark records could preserve its native bill.
    BILLS = %w[cost cost_in_usd_ticks].freeze
    # THE SETTLEMENT FACTS A RECORDED CALL'S SPEND CARRIES beside its counts and bills, as its wire
    # said them: the broker's `is_byok` and the `service_tier` the answer served. They are not
    # counts — a spend summed over calls keeps one only when every call says the same.
    SETTLEMENT_FACTS = %w[is_byok service_tier].freeze

    # THE KERNEL'S RETRY, ON A CALL NO RUNNER MAKES. The model runner asks again after a lost
    # connection, a timeout or an overloaded answer — the one list, `ApplyResult.transient_error?`,
    # read here and never restated — until the invocation's three calls are spent, ten seconds
    # more apart each time. A bench's call goes to the provider with no runner between, so without
    # this a reset the product would have retried read as the model missing the text. A provider's
    # Retry-After is not read, so a call's retries wait thirty seconds in all.
    ATTEMPTS = 3
    PAUSE = ->(seconds) { sleep(seconds) }
    CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

    # One call through the retry: its result, or the last call's error, every retry before it as
    # the error it answered and the pause it took, so a reading counts them, and `seconds` — the
    # monotonic span of the last attempt, the one that answered (or failed for good), to the
    # millisecond: the failed attempts and the pauses before it are what the retries name.
    Called = Data.define(:result, :error, :retries, :seconds) do
      # The retries as a sample records them, absent when the first call answered; the seconds
      # always.
      def facts = (retries.empty? ? {} : { "retries" => retries }).merge("seconds" => seconds)
    end

    module_function

    # THE PAID GATE, before any request is built: explicit opt-in, never CI, development only, and
    # every key the run will read.
    def validate!(env = ENV, key_names: [])
      raise ArgumentError, "set E2E_LIVE=1 to make a paid provider call" unless env["E2E_LIVE"] == "1"
      raise ArgumentError, "real-provider calls are local-development only" unless env["CI"].to_s.empty?
      raise ArgumentError, "real-provider calls require RAILS_ENV=development" unless env["RAILS_ENV"].to_s == "development"

      missing = key_names.find { |name| env[name].to_s.empty? }
      raise ArgumentError, "#{missing} is not set" if missing

      true
    end

    # A routed ref's client: the lane the ref names, the id its wire carries. `adapter` is the
    # gem's transport seam; nil selects the gem's default.
    def for(route, env: ENV, timeout: TIMEOUT_SECONDS, adapter: nil)
      client(lane: route.lane, model: route.model, env: env, timeout: timeout, adapter: adapter)
    end

    def client(lane:, model:, env: ENV, timeout: TIMEOUT_SECONDS, capabilities: CAPABILITIES, adapter: nil)
      SimpleInference::Client.new(
        base_url: lane.base_url,
        api_key: env.fetch(lane.key_name),
        timeout: timeout,
        adapter: adapter,
        execution_profile: profile(lane: lane, model: model, capabilities: capabilities)
      )
    end

    # THE KERNEL'S CACHE MARKERS ON A BENCH CALL: the one placer (`Nexus::PromptCache::Breakpoints`)
    # over the call's own instructions and input, gated by the one predicate Build places by
    # (`WireLowering.explicit_cache_breakpoints?` over the client's profile — Anthropic's wire alone;
    # every other wire caches a stable prefix implicitly and is handed its material unchanged).
    # Unmarked, every Anthropic draw paid the full input rate on a tool set a production round reads
    # from cache. The call's `instructions:` and `input:`, in that order, and the routing key when
    # the wire takes one (`cache_key`).
    def cached(client, instructions:, input:, env: ENV)
      placement = Nexus::PromptCache::Breakpoints.apply(
        instructions: instructions, input: input,
        capable: ModelRequests::WireLowering.explicit_cache_breakpoints?(client.execution_profile), tier: CACHE_TIER
      )
      { instructions: placement.instructions, input: placement.input }.merge(cache_key(client, env))
    end

    # THE KERNEL'S ROUTING KEY ON A BENCH CALL: OpenAI routes its prefix cache by `prompt_cache_key`
    # on the wires Build keys (`WireLowering.carries_cache_key?`), so a benchmark names one key per
    # (arm, lane) in `E2E_BENCH_CACHE_KEY` and its draws share a warm prefix the way a loop's rounds
    # do. Unkeyed, sol read no cached token on any first round. Every other wire is handed nothing:
    # the gem refuses an option its wire does not declare. No key named, none sent.
    def cache_key(client, env)
      key = env["E2E_BENCH_CACHE_KEY"].to_s
      if key.empty? || !ModelRequests::WireLowering.carries_cache_key?(client.execution_profile.adapter_profile)
        {}
      else
        { prompt_cache_key: key }
      end
    end
    private_class_method :cache_key

    # The block is the call; `pause` sleeps between calls and `clock` times each one (a test
    # passes its own).
    def retrying(pause: PAUSE, clock: CLOCK, &request)
      attempt(request, ordinal: 1, retries: [], pause: pause, clock: clock)
    end

    # An error as every bench records one: its class, then the start of its message.
    def error_text(error) = "#{error.class}: #{error.message[0, 200]}"

    # ONE CALL'S OWN FACTS, the one reader every bench records a call through: the provider's
    # finish as its wire says it, the typed reason the lane carries beside it (the Responses family
    # says `incomplete` and puts why in its detail), the gem's reading of that reason — an exhausted
    # output budget reads as one word on every wire — and the spend. Absent facts are left out.
    def facts(result, lane)
      { "finish" => result.finish_reason&.to_s, "finish_detail" => result.finish_detail&.to_s,
        "finish_quality" => SimpleInference::FinishQuality.for(adapter_profile: lane.format, detail: result.finish_detail),
        "usage" => spend(result.usage, lane.format) }.compact
    end

    # THE CALL'S SPEND in one shape across every wire a bench reaches, read by the receipt's own
    # reader (`UsageRecords::Tokens`): input with the cache classes folded in (Anthropic reports
    # them beside `input_tokens`), output, the two cache classes, the provider's own bill (`BILLS`:
    # the broker's charge as `cost`, xAI's as the integer `cost_in_usd_ticks` the wire sent; the
    # direct DeepSeek lane reports none), and the two facts settlement prices by as the wire said
    # them — the broker's `is_byok` (its `cost` is the whole bill only when it is `false`) and the
    # `service_tier` the Responses wire says it served. Absent when the provider reported nothing;
    # each fact absent when the usage did not carry it.
    def spend(usage, adapter_profile)
      counts = UsageRecords::Tokens.read(usage, adapter_profile: adapter_profile)
      reported = Hash(usage)
      { "input_tokens" => counts[:input_tokens], "output_tokens" => counts[:output_tokens],
        "cache_read_tokens" => counts[:cache_read_tokens], "cache_creation_tokens" => counts[:cache_creation_tokens],
        "cost" => reported["cost"]&.to_f, "cost_in_usd_ticks" => reported["cost_in_usd_ticks"],
        "is_byok" => reported["is_byok"], "service_tier" => reported["service_tier"] }
        .compact.presence
    end
    private_class_method :spend

    # `ordinal` is the call about to be made, as the kernel counts an invocation's attempts.
    def attempt(request, ordinal:, retries:, pause:, clock:)
      started = clock.call
      begin
        result = request.call
        Called.new(result: result, error: nil, retries: retries, seconds: span(clock, started))
      rescue StandardError => error
        if ordinal < ATTEMPTS && ModelInvocations::ApplyResult.transient_error?(error)
          cooldown = ModelInvocations::ApplyResult::RETRY_COOLDOWN_STEP * ordinal
          pause.call(cooldown)
          attempt(request, ordinal: ordinal + 1, pause: pause, clock: clock,
            retries: retries + [{ "error" => error_text(error), "pause_seconds" => cooldown }])
        else
          Called.new(result: nil, error: error, retries: retries, seconds: span(clock, started))
        end
      end
    end
    private_class_method :attempt

    def span(clock, started) = (clock.call - started).round(3)
    private_class_method :span

    def profile(lane:, model:, capabilities:)
      defaults = SimpleInference::ApiFormat.defaults(lane.format)
      workload = SimpleInference::ApiFormat.workload(lane.format)
      SimpleInference::ExecutionProfile.new(
        **defaults,
        profile_id: "manual/#{model}@#{lane.format}",
        provider_id: lane.provider_id,
        adapter_profile: lane.format,
        workload: workload,
        model_pin: model,
        credential_lane: "api_key",
        capabilities: capabilities,
        input_modalities: Hash(defaults[:input_media]).keys,
        total_execution_deadline_seconds: SimpleInference::ApiFormat.deadline_seconds(workload)
      )
    end
  end
end
