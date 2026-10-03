require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "evals_drawings"

# A PROVIDER'S REFUSAL, READ OFF THE TASK ROWS: the facts a record keeps of the steps a classifier
# declined — `refused_steps`, `refusals`, `refusals_served`, `model_switches`, the first standing
# refusal's own sentence — are read off the loop row's tasks the artifact already stores, never the
# feed, so a re-score reads what the lane read. A refusal that STOOD is the class `provider
# refused`, read after the kernel's own signal and a disagreement; a refusal the answerer's declared
# fallback SERVED is green and a fact, printed as `fb=M`. A settled race's loser refused after the
# race had its answer is the race's residue, never a refused step; a switched spine round is the
# fallback's cold write, never the cache bar's. Pure Ruby over drawn traces.
class EvalsRefusalsTest < Minitest::Test
  include EvalsFixtureBench
  D = E2E::Evals::Drawing
  S = E2E::Evals::Scorecard
  REFUSING_MODEL = "alternate/strong".freeze
  FALLBACK_MODEL = "alternate/fallback".freeze
  # The kernel's own sentence on a step that stood, as `RefusalSentence` writes it for the reading
  # model.
  STOOD = "#{REFUSING_MODEL} declined this step (cyber), so it failed with no output; @rho declares no fallback model, " \
          "so nothing re-ran it".freeze
  ABANDONED = "#{REFUSING_MODEL} declined this step (cyber), so it failed with no output; nothing waits for it any more, " \
              "so nothing re-ran it".freeze
  SERVED = { "model_change" => { "from" => REFUSING_MODEL, "reason" => "model_refused", "category" => "cyber" } }.freeze

  # ── the facts ─────────────────────────────────────────────────────────

  # THE STATUS-AGNOSTIC READ: a model row whose summary carries a declined finish is a refused step
  # whatever its status — the kernel fails a refusal that stood (`model_refused`, the category
  # beside the quality), and a record from before that change carries a `completed` row with the
  # quality alone — so one read counts both. The category tallies under the row's own model, `none`
  # the harness's one key for a row with no category (the provider named none, or the row predates
  # the column).
  def test_a_refusal_that_stood_is_counted_off_the_task_rows_whatever_its_status
    trace = pairing(
      D.round("r2t0-model-1", model: REFUSING_MODEL),
      D.round("r2t0-model-2", status: "failed", model: REFUSING_MODEL,
        result: { "finish_quality" => "refused", "refusal_category" => "cyber" },
        error: { "key" => "model_refused", "detail" => STOOD }),
      D.round("r2t0-model-3", model: REFUSING_MODEL, result: { "finish_quality" => "refused" })
    )
    facts = trace.structure_facts
    assert_equal 2, facts["refused_steps"]
    assert_equal({ REFUSING_MODEL => { "cyber" => 1, "none" => 1 } }, facts["refusals"])
    assert_equal 0, facts["refusals_served"]
    assert_equal 0, facts["model_switches"]
    assert_equal STOOD, facts["refusal_detail"], "the first standing refusal's own sentence"
    assert_equal({ "model_refused" => 1 }, facts["round_errors"], "the failure key rides the round errors unchanged")
    blocked = pairing(D.round("r2t0-model-2", status: "failed", model: REFUSING_MODEL,
      result: { "finish_quality" => "blocked", "refusal_category" => "SPII" }, error: { "key" => "model_refused", "detail" => "x" }))
    assert_equal [1, { REFUSING_MODEL => { "SPII" => 1 } }], blocked.structure_facts.values_at("refused_steps", "refusals"),
      "a content block is a declined step too"
    clean = pairing(D.round("r2t0-model-1", model: REFUSING_MODEL, result: { "finish_quality" => "output_budget_exhausted" }))
    assert_equal [0, {}, nil], clean.structure_facts.values_at("refused_steps", "refusals", "refusal_detail"),
      "another caveat is no refusal: read, and none"
  end

  # A SWITCH IS A ROW FACT: the switched step's summary names what it replaced (`model_change`
  # without `to` — the row's own model says it). A refused switch whose fallback answered is SERVED;
  # its refusal tallies under the model that declined, with its category. A fallback that declined
  # too stands, so its row is a refused step and never a served one, both refusals tallied; a
  # switched step a stop cut before the fallback answered was served nothing. An unavailable switch
  # is a switch and no refusal.
  def test_a_served_refusal_counts_the_switch_and_tallies_the_refusal_under_the_model_that_declined
    trace = pairing(
      D.round("r2t0-model-1", model: FALLBACK_MODEL, result: SERVED),
      D.round("r2t0-model-2", status: "failed", model: FALLBACK_MODEL,
        result: SERVED.merge("finish_quality" => "refused", "refusal_category" => "general_harms"),
        error: { "key" => "model_refused", "detail" => "#{FALLBACK_MODEL} declined this step (general_harms), so it failed with no output; " \
                                                         "it was already re-run once after #{REFUSING_MODEL} declined it (cyber), so nothing re-ran it again" }),
      D.round("r2t0-model-3", model: FALLBACK_MODEL, result: { "model_change" => { "from" => REFUSING_MODEL, "reason" => "missing_credential" } }),
      D.round("r2t0-model-4", status: "canceled", model: FALLBACK_MODEL, result: SERVED, error: { "key" => "creator_requested" })
    )
    facts = trace.structure_facts
    assert_equal 1, facts["refused_steps"], "the fallback declined too: that step stood"
    assert_equal({ REFUSING_MODEL => { "cyber" => 3 }, FALLBACK_MODEL => { "general_harms" => 1 } }, facts["refusals"])
    assert_equal 1, facts["refusals_served"], "the step the fallback answered; never the one it declined nor the one a stop cut"
    assert_equal 4, facts["model_switches"], "every switch, the unavailable one among them"
  end

  # THE RACE'S RESIDUE: a refusal that won the first-terminal race against the loser cancel settles
  # `failed / model_refused` after its race had its answer (the kernel's `abandoned` stand, honest on
  # the row). A settled race's losing arm is read apart through the race-settlement read, so the run
  # is not red for a step nothing waited for; the same refusal while the race is still open counts.
  def test_a_settled_races_loser_refused_after_the_race_had_its_answer_is_no_refused_step
    settled = race(join_status: "completed")
    assert_equal 0, settled.structure_facts["refused_steps"]
    assert_equal({}, settled.structure_facts["refusals"])
    assert_equal({ "model_refused" => 1 }, settled.structure_facts["round_errors"], "the row stays honest")
    assert_nil S.classify(record_of(settled)), "the loser's key is no kernel finding and no provider refusal"

    open = race(join_status: "running")
    assert_equal 1, open.structure_facts["refused_steps"], "a race with no answer yet: the refusal stood"
    assert_equal S::PROVIDER_REFUSED, S.classify(record_of(open))
  end

  # ── the class, the line, the bar ──────────────────────────────────────

  # `provider refused` IS READ AFTER THE KERNEL: a refused step that stood reds the run with the
  # facts' reason and the kernel's own sentence; a record that also carries a kernel error is a
  # kernel finding; `model_refused` alone is never one; a `halt_failure` the refused spine round
  # parked the loop on is the refusal's, never an unscripted attention. The pre-change shape (a
  # completed row carrying the quality) reads the same class on a record whose predicates passed.
  def test_a_refusal_that_stood_is_provider_refused_after_the_kernel_signal
    stood = pairing(D.round("r2t0-model-2", status: "failed", model: REFUSING_MODEL,
      result: { "finish_quality" => "refused", "refusal_category" => "cyber" }, error: { "key" => "model_refused", "detail" => STOOD }))
    red = record_of(stood, succeeded: false, task_pass: nil)
    assert_equal S::PROVIDER_REFUSED, S.classify(red)
    assert_nil S.kernel_signal(red), "a refusal is the provider's, never the kernel's"
    assert_equal "1 step refused (cyber) on #{REFUSING_MODEL} — #{STOOD}", S.reason_of(red)
    assert_equal "- shape-linear nexus #1: provider refused — 1 step refused (cyber) on #{REFUSING_MODEL} — #{STOOD}", S.red_line(red)
    assert_equal S::PROVIDER_REFUSED, S.classify(record_of(stood)), "red whatever the predicate read"

    before = pairing(*%w[r2t0-model-2 r2t0-model-3 r2t0-model-4].map { |key| D.round(key, model: REFUSING_MODEL, result: { "finish_quality" => "refused" }) })
    assert_equal S::PROVIDER_REFUSED, S.classify(record_of(before))
    assert_equal "3 steps refused (none) on #{REFUSING_MODEL}", S.reason_of(record_of(before)), "no sentence on the row: the facts alone"

    kernel = record_of(stood, facts: { "round_errors" => { "model_refused" => 1, "expand_failed" => 1 } })
    assert_equal S::KERNEL_FINDING, S.classify(kernel)
    assert_equal "a round failed: expand_failed", S.reason_of(kernel)

    halted = record_of(stood, succeeded: false, task_pass: nil, facts: { "attention_reasons" => { "halt_failure" => 1 } })
    assert_equal S::PROVIDER_REFUSED, S.classify(halted), "the refused spine round's halt is the refusal's"
    unrefused = record_of(pairing, succeeded: false, task_pass: nil, facts: { "attention_reasons" => { "halt_failure" => 1 } })
    assert_equal S::KERNEL_FINDING, S.classify(unrefused), "without a refused step the halt stays unscripted"

    apart = record_of(stood, succeeded: false, task_pass: true)
    assert_equal S::DISAGREEMENT, S.classify(apart), "the two scorers apart are read before the provider"
  end

  # A SERVED REFUSAL IS GREEN AND A FACT: the fallback answered, the predicate passed — no class, the
  # line's `fb=<served>` token; an unavailable switch alone prints no token.
  def test_a_served_refusal_is_green_and_prints_its_token_and_an_unavailable_switch_prints_none
    served = record_of(pairing(D.round("r2t0-model-2", model: FALLBACK_MODEL, result: SERVED)))
    assert_nil S.classify(served)
    assert_equal 1, served.dig("facts", "refusals_served")
    assert_match(/ seconds=60 fb=1\z/, E2E::Evals::ReportLine.render(served))

    switched = record_of(pairing(D.round("r2t0-model-2", model: FALLBACK_MODEL, result: { "model_change" => { "from" => REFUSING_MODEL, "reason" => "missing_credential" } })))
    assert_nil S.classify(switched)
    assert_equal 1, switched.dig("facts", "model_switches")
    refute_match(/fb=/, E2E::Evals::ReportLine.render(switched))
  end

  # THE CACHE BAR SKIPS A SWITCHED SPINE ROUND: its usage is the fallback's own cold write, so the
  # series leaves it out as a designed miss — a green, served record never reads `cache under floor`
  # for the switch.
  def test_the_cache_series_leaves_a_switched_spine_round_out
    usage = ->(input, read) { { "input_tokens" => input, "cache_read_tokens" => read } }
    graph = D.graph([D.n("r1", "model_task"), D.n("r2", "model_task"), D.n("r3", "model_task")], [%w[r1 r2], %w[r2 r3]])
    trace = D.trace(graph, [D.round("r1", model: REFUSING_MODEL, usage: usage.(1000, 0)),
                            D.round("r2", model: FALLBACK_MODEL, result: SERVED, usage: usage.(1100, 0)),
                            D.round("r3", model: FALLBACK_MODEL, usage: usage.(1200, 1100))], [])
    assert_equal({ "r1" => [1000, 0], "r3" => [1200, 1100] }, trace.cache_read_series)
  end

  # THE SPLIT IS THE KERNEL'S: `efficiency.cost_by_model` is the phases route's `spend.by_model`,
  # copied, never priced here; a spend with no split reads nil (not read).
  def test_the_cost_split_is_copied_off_the_routes_spend
    by_model = { REFUSING_MODEL => { "input_tokens" => 10, "output_tokens" => 1, "cache_read_tokens" => 0, "cost_amount" => "0.05", "cost_unit" => "USD" },
                 FALLBACK_MODEL => { "input_tokens" => 20, "output_tokens" => 2, "cache_read_tokens" => 0, "cost_amount" => "0.02", "cost_unit" => "USD" } }
    spend = { "input_tokens" => 30, "output_tokens" => 3, "cost_amount" => "0.07", "cost_unit" => "USD", "by_model" => by_model }
    assert_equal by_model, D.trace(D.graph([], []), [], [], spend: spend).efficiency["cost_by_model"]
    assert_nil D.trace(D.graph([], []), [], [], spend: spend.except("by_model")).efficiency["cost_by_model"]
  end

  private

    # compose-three-stage-pairing's shape: `r1` reads, `r2` makes the compose call `r2t0`, whose
    # members are the drawn rows (never the spine's), and `r3` answers.
    def pairing(*members)
      nodes = [D.n("r1", "model_task"), D.n("r2", "model_task"), D.n("r2t0", "tool_task", expansion_parent: "r2"),
               *members.map { |row| D.n(row["key"], "model_task", status: row["status"], spine: false, expansion_parent: "r2t0") },
               D.n("r3", "model_task", deliverable: true, expansion_parent: "r2", input_from: %w[r2 r2t0])]
      edges = [%w[r1 r2], %w[r2 r2t0], *members.map { |row| ["r2t0", row["key"]] }, %w[r2t0 r3]]
      D.trace(D.graph(nodes, edges), [D.tool("r2t0", "compose", after: ["r2"]), *members], [])
    end

    # Two model arms raced under `r1t0`, `r1t0-model-1` answering and `r1t0-model-2` refused — after
    # the race settled (the kernel's `abandoned` stand), or while it is still open.
    def race(join_status:)
      join = "r1t0-parallel-1"
      arms = %w[r1t0-model-1 r1t0-model-2]
      nodes = [D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"),
               D.n(arms[0], "model_task", spine: false, expansion_parent: "r1t0"),
               D.n(arms[1], "model_task", status: "failed", spine: false, expansion_parent: "r1t0"),
               D.n(join, "join_task", status: join_status, join: EvalsDrawings::RACE, expansion_parent: "r1t0"),
               D.n("r2", "model_task", deliverable: true, expansion_parent: "r1", input_from: %w[r1 r1t0])]
      graph = D.graph(nodes, [%w[r1 r1t0], ["r1t0", arms[0]], ["r1t0", arms[1]], [arms[0], join], [arms[1], join], %w[r1t0 r2]])
      graph = graph.merge("edges" => graph["edges"].map { |edge| edge.merge("structural" => true) })
      outcomes = { arms[0] => "completed", arms[1] => "waiting" }
      rows = [D.round(arms[0], model: REFUSING_MODEL),
              D.round(arms[1], status: "failed", model: REFUSING_MODEL, result: { "finish_quality" => "refused", "refusal_category" => "cyber" },
                error: { "key" => "model_refused", "detail" => ABANDONED }),
              EvalsDrawings.settled(join, join_status == "completed" ? outcomes : {}, status: join_status)]
      D.trace(graph, [D.tool("r1t0", "compose", after: ["r1"]), *rows], [])
    end

    # The lane's record over the trace (`EvalsLaneTest#build_record`'s facts and efficiency), green
    # unless drawn otherwise; `facts` overrides a fact by name.
    def record_of(trace, succeeded: true, task_pass: true, facts: {})
      D.record(succeeded: succeeded, task_pass: task_pass,
        facts: trace.structure_facts.merge(facts), efficiency: trace.efficiency.merge("compactions_survived" => 0))
    end
end
