require "active_support/all"
require_relative "../../nexus/lib/nexus/model_tool_calls"
require_relative "adaptation_rows"
require_relative "evals/bench"
require_relative "manual_client"
require_relative "provider_lanes"
require_relative "task_bench/declared_set"
require_relative "task_bench/objectives"
require_relative "output_caps"
require_relative "task_bench/report"
require_relative "task_bench/sample"

module E2E
  # THE TOOLS' LANE: `DeclaredSet` is what a rho turn declares, `Objectives` score one emitted
  # message by property, `Sample` runs one two-step draw — read-only messages answered from the
  # objective's fixture (`ReadClass`, `Emulator`) until the first message that is not, up to three —
  # and records every call, `Report` writes the readout. The cross-turn half — a background `task`
  # whose result arrives as mail in the next turn — is `test/live_task_mail_test.rb`, driven through
  # `exe/rho`.
  module TaskBench
    # `E2E_BENCH_MODELS`: catalog refs, each on the lane its provider segment names
    # (`ProviderLanes.route`); none named = the evals' own floor, the direct DeepSeek lane first.
    WEAK_MODELS = ENV.fetch("E2E_BENCH_MODELS", Evals::Bench.read.tiers.fetch(Evals::Bench::FLOOR).join(",")).split(",").freeze
    # THE STYLE AXIS: which spelling of `task`/`ask` the set declares — `nexus`, `claude`, `codex`,
    # or presets joined by `+`; the baseline alone by default. Each id is checked at first use.
    STYLES = ENV.fetch("E2E_BENCH_STYLES", "nexus").split(",").map(&:strip).reject(&:empty?).freeze
    # `E2E_BENCH_CANDIDATES=<row>/<id>,…` (the RUN step's text probes): `lead_hints` and
    # `tool_descriptions` candidates of the SDK pack's harness candidates — a hint joins rho's
    # instructions block, an entry joins the declared set — each on the models its row covers; none
    # named = the baseline cells; an unknown key, another kind, a candidate covering no selected
    # model, or one its row pairs with a floor-tier model is refused before a call is paid.
    CANDIDATES = AdaptationRows.list(ENV["E2E_BENCH_CANDIDATES"], kinds: %w[lead_hints tool_descriptions]).freeze
    CELLS = AdaptationRows.cells(CANDIDATES, WEAK_MODELS).freeze
  end
end
