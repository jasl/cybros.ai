require "active_support/all"
require_relative "adaptation_rows"
require_relative "evals/bench"
require_relative "manual_client"
require_relative "provider_lanes"
require_relative "compose_bench/buckets"
require_relative "compose_bench/endpoints"
require_relative "compose_bench/executed"
require_relative "compose_bench/inline"
require_relative "compose_bench/objectives"
require_relative "compose_bench/picture"
require_relative "compose_bench/probe"
require_relative "compose_bench/replay"
require_relative "compose_bench/report"
require_relative "compose_bench/rows"
require_relative "compose_bench/scoring"
require_relative "compose_bench/shape"
require_relative "compose_bench/styles"
require_relative "compose_bench/tools"
require_relative "compose_bench/waits"

module E2E
  # THE VALID-FIRST BENCH: the shipped `compose` bytes and their re-cuts, against the two weak
  # models, on objectives whose prompts state a task and whose pictures were written by hand. The
  # pieces: `Rows` (the bytes), `Objectives` (task + picture), `Tools` (what is declared beside
  # compose), `Styles` (which spelling of `task`/`ask` stands beside it), `Probe` (one sample, one
  # repair), `Scoring` (one script through the evaluator and the lowering, and one graph against a
  # picture), `Shape` (the written-order lowering), `Executed` (the plan the kernel placed, which the
  # evals score where the trace holds it), `Picture` (exactness and the silent buckets), `Buckets`
  # (the loud ones), `Report`.
  module ComposeBench
    # `E2E_BENCH_MODELS`: catalog refs, each on the lane its provider segment names
    # (`ProviderLanes.route`); none named = the evals' own floor, so the direct DeepSeek lane the
    # floor runs on is the one measured here too.
    WEAK_MODELS = ENV.fetch("E2E_BENCH_MODELS", Evals::Bench.read.tiers.fetch(Evals::Bench::FLOOR).join(",")).split(",").freeze
    SAMPLES = Integer(ENV.fetch("E2E_BENCH_SAMPLES", "3"))
    # `E2E_BENCH_STYLES=nexus,claude,codex,nexus+claude`: the baseline alone by default.
    STYLES = Styles.all.freeze
    # `E2E_BENCH_CANDIDATES=<row>/<id>,…` (the RUN step's text probes): `lead_hints` candidates of
    # the SDK pack's harness candidates, each on the models its row covers; none named = the
    # baseline cells; an unknown key, another kind, a candidate covering no selected model, or one
    # its row pairs with a floor-tier model is refused before a call is paid.
    CANDIDATES = AdaptationRows.list(ENV["E2E_BENCH_CANDIDATES"], kinds: %w[lead_hints]).freeze
    CELLS = AdaptationRows.cells(CANDIDATES, WEAK_MODELS).freeze
  end
end
