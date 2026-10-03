require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "digest"
require "date"
require "minitest/mock"
require "tmpdir"
require "yaml"

# The authored bench exercises selection, limits and planning independently of paid evaluations.
# Explicit adaptation cases below also verify the shipped pack rows and catalog references.
class EvalsBenchTest < Minitest::Test
  include EvalsFixtureBench
  BENCH = EvalsFixtureBench.read
  CORPUS = E2E::Evals::Corpus.load(canary: BENCH.canary)
  E2E_ROOT = File.expand_path("..", __dir__)
  ENV_NONE = {}.freeze
  PACK = CybrosAgent::ModelAdaptations.load
  # These cases exercise the shipped model adaptation rows themselves. Their policy is still
  # authored here rather than imported from the paid benchmark configuration.
  ADAPTATION_BENCH = BENCH.with(document: BENCH.document.merge(
    "tiers" => { "strong" => %w[openrouter/z-ai/glm-5.3 openrouter/moonshotai/kimi-k3],
                 "floor" => %w[deepseek/deepseek-flash openrouter/z-ai/glm-5.3-flash] },
    "named_only" => { "strong" => ["openai_api/gpt-6.1-sol"], "floor" => ["openai_api/gpt-6-luna"] },
    "fallbacks" => {}
  ))
  CATALOG_FILES = Dir[File.expand_path("../../nexus/config/model_catalog/*.yml", __dir__)].sort
  CANDIDATE_FILES = Dir[File.expand_path("../evals/candidates/*.yml", __dir__)].sort
  SUMMARIZER_FILE = File.expand_path("../../nexus/app/services/conversations/compaction/summarizer.rb", __dir__)
  CANDIDATE_KINDS = { "tool_style" => "value", "lead_hints" => "text", "summarizer_prompt" => "recut", "tool_descriptions" => "entry" }.freeze
  # THE TEST'S OWN SUMMARIZER CANDIDATE: a `summarizer_prompt` of glm's gem row built in memory —
  # `Candidate.new` handed to the loader's `find`, the door the floor test hands its hint through —
  # one anchored edit of the kernel's closing line. The files carry NO summarizer candidate:
  # `glm-5.3/k1-execute-not-narrate` was read in the paid window (cell 5c, n=2: pass 2/2, pointers
  # 2/2, rounds 6 and 8 against 12a's 6/6/5, not better) and DELETED 2026-09-16.
  ANCHOR = "Write only the summary; no commentary about summarizing.".freeze
  SENTENCE = "This sentence is the test's.".freeze
  SUMMARIZER = E2E::AdaptationRows::Candidate.new(row_id: "glm-5.3", id: "test-closing-sentence", kind: "summarizer_prompt",
    payload: { "anchor" => ANCHOR, "replacement" => "#{ANCHOR} #{SENTENCE}" }, seed: "the test's own; never a file")
  # THE TEST'S OWN HINT AND WORD: no candidate is on file, so the door's other kinds are read through
  # candidates built in memory as SUMMARIZER is — a `lead_hints` line on kimi's row, a `tool_style`
  # word on glm's.
  HINT = E2E::AdaptationRows::Candidate.new(row_id: "kimi-k3", id: "test-hint", kind: "lead_hints", payload: "The test's line.",
    seed: "the test's own; never a file")
  WORD = E2E::AdaptationRows::Candidate.new(row_id: "glm-5.3", id: "test-word", kind: "tool_style", payload: ["workflow"],
    seed: "the test's own; never a file")

  # The model names below belong to this fixture, independent of the manual evaluation roster.
  def test_tiers_named_models_and_limits_are_read_from_the_supplied_bench
    assert_equal %w[fixture/strong fixture/second], BENCH.tiers.fetch("strong")
    assert_equal %w[fixture/floor fixture/exempt], BENCH.tiers.fetch("floor")
    assert_equal E2E::Evals::Bench::TIERS, BENCH.tiers.keys
    assert_equal [E2E::Evals::Bench::STRONG, E2E::Evals::Bench::FLOOR], E2E::Evals::Bench::TIERS
    assert_equal E2E::Evals::Bench::TIERS, E2E::Evals::Corpus::TIERS
    assert_equal E2E::Evals::Bench::TIERS, E2E::Evals::TerminalBench::TIERS
    assert_empty E2E::Evals::AgentsOnRails::TIERS - E2E::Evals::Bench::TIERS
    assert_equal({ "tier" => "strong" }, BENCH.tier_fact("fixture/strong"))
    assert_equal({ "tier" => "floor" }, BENCH.tier_fact("fixture/floor"))
    assert_equal({ "tier" => nil }, BENCH.tier_fact("fixture/unknown"))
    assert_equal({ "strong" => %w[alternate/strong alternate/fallback], "floor" => ["alternate/floor"] }, BENCH.named_only)
    assert_equal BENCH.tiers.keys, BENCH.named_only.keys
    assert_empty BENCH.models & BENCH.named_only.values.flatten
    assert_equal "strong", BENCH.tier_of("alternate/strong")
    assert_equal "strong", BENCH.tier_of("alternate/fallback")
    assert_equal "floor", BENCH.tier_of("alternate/floor")
    assert_equal({ "alternate/strong" => "alternate/fallback" }, BENCH.fallbacks)
    assert_equal 3, BENCH.runs_per_task
    assert_equal %w[nexus workflow pack], BENCH.tool_styles
    assert_equal "bypass", BENCH.approval
    assert_equal 600, BENCH.deadline_seconds
    assert_in_delta 8.0, BENCH.cost_stop_usd
    assert_in_delta 12.0, BENCH.cost_stop_usd_for("compaction-wall-kernel")
    assert_in_delta 20.0, BENCH.cost_stop_usd_for("exit-long", family: "exit")
    assert_in_delta 20.0, BENCH.cost_stop_usd_for("alpha-one", family: "terminal-bench")
    assert_in_delta 8.0, BENCH.cost_stop_usd_for("shape-linear", family: "shape")
    assert_equal 1, BENCH.version
    assert_equal 1, BENCH.unattended_answers_per_run
    assert_equal "No person is available to answer in this run. Continue with your own judgement.", BENCH.unattended_answer_text
    assert_match(/\A[0-9a-f-]{36}\z/, BENCH.canary)
    assert_equal File.expand_path("../artifacts/evals/runs", __dir__), BENCH.runs_dir
  end

  def test_cache_floors_read_the_configured_families_and_exemptions
    assert_equal({ "shape" => 0.85, "exit" => 0.85, "compose" => 0.8, "compaction" => 0.75 }, BENCH.cache_floor_by_family)
    assert_equal 2, BENCH.cache_floor_min_rounds
    assert_equal ["fixture/exempt"], BENCH.cache_floor_exempt_models
    %w[fixture/strong fixture/second fixture/floor alternate/strong alternate/floor].each do |model|
      assert_in_delta 0.85, BENCH.cache_floor_for("exit", model: model)
    end
    assert_nil BENCH.cache_floor_for("exit", model: "fixture/exempt")
    assert_nil BENCH.cache_floor_for("spawn", model: "fixture/strong")
  end

  def test_terminal_bench_policy_reads_the_registered_dataset_and_model_cells
    policy = E2E::Evals::TerminalBench::Policy.of(BENCH)
    assert_equal "sample@1", BENCH.terminal_bench.fetch("dataset")
    assert_equal %w[alpha-one beta-two], policy.names
    assert_equal({ "models" => ["fixture/floor"], "runs" => 3 }, BENCH.terminal_bench.fetch("cell"))
    assert_equal({ "models" => %w[fixture/second fixture/strong], "runs" => 3 }, BENCH.terminal_bench.fetch("optional_cell"))
  end

  def test_the_digest_is_the_files_sha256_and_stable
    assert_equal Digest::SHA256.hexdigest(File.read(BENCH.path, encoding: Encoding::UTF_8)), BENCH.digest
    assert_equal BENCH.digest, EvalsFixtureBench.read.digest
    assert_equal BENCH.digest[0, 12], BENCH.short_digest
  end

  def test_subset_takes_the_whole_bench_by_default_with_the_first_style_row_alone
    selection = BENCH.subset(ENV_NONE, today: Date.new(2026, 9, 10))
    assert_equal "*", selection.tasks_glob
    assert_equal BENCH.models, selection.models
    assert_equal ["nexus"], selection.styles, "the alias row is opted in, not paid for by every family"
    assert_equal 3, selection.runs
    assert_equal "2026-09-10-#{BENCH.models.map { |m| m.tr("/", "_") }.join("+")}", selection.label
    assert_equal BENCH.runs_dir, selection.runs_dir
    assert_equal File.join(BENCH.runs_dir, selection.label), selection.run_dir
    refute selection.models_named, "the bench's whole list is not a naming: an optional model stays off"
  end

  def test_subset_narrows_by_env_and_dates_the_label
    env = { "E2E_EVALS_TASKS" => "shape-*", "E2E_EVALS_MODELS" => "fixture/strong, fixture/floor",
            "E2E_EVALS_STYLES" => "workflow,nexus", "E2E_EVALS_RUNS" => "1", "E2E_EVALS_LABEL" => "smoke",
            "E2E_EVALS_RUNS_DIR" => "/tmp/evals-runs" }
    selection = BENCH.subset(env, today: Date.new(2026, 9, 11))
    assert_equal "shape-*", selection.tasks_glob
    assert_equal %w[fixture/strong fixture/floor], selection.models
    assert_equal %w[workflow nexus], selection.styles
    assert_equal 1, selection.runs
    assert_equal "2026-09-11-smoke", selection.label
    assert_equal "/tmp/evals-runs", selection.runs_dir
    assert selection.models_named
    dated = BENCH.subset(env.merge("E2E_EVALS_LABEL" => "2026-09-09-rerun"), today: Date.new(2026, 9, 11))
    assert_equal "2026-09-09-rerun", dated.label, "a label that carries its date keeps it"
  end

  # THE RUN'S LOWER PATIENCE IN MONEY: `E2E_LIVE_COST_STOP_USD` (the live
  # lanes' word) may LOWER a task's stop for one invocation — a smoke on a
  # costly model — and never raise it: the bench's stop is policy.
  def test_subset_takes_a_lower_cost_stop_from_the_env_and_never_a_higher_one
    assert_nil BENCH.subset(ENV_NONE).cost_stop_ceiling
    assert_in_delta 8.0, BENCH.subset(ENV_NONE).cost_stop_usd(8.0)
    lowered = BENCH.subset({ "E2E_LIVE_COST_STOP_USD" => "2" })
    assert_in_delta 2.0, lowered.cost_stop_usd(8.0)
    assert_in_delta 1.5, lowered.cost_stop_usd(1.5), 0.001, "a task stop already lower stays"
    assert_in_delta 8.0, BENCH.subset({ "E2E_LIVE_COST_STOP_USD" => "30" }).cost_stop_usd(8.0), 0.001, "never raised"
    assert_raises(ArgumentError) { BENCH.subset({ "E2E_LIVE_COST_STOP_USD" => "two" }) }
    assert_raises(ArgumentError) { BENCH.subset({ "E2E_LIVE_COST_STOP_USD" => "0" }) }
  end

  def test_subset_refuses_a_stranger
    stranger = assert_raises(ArgumentError) { BENCH.subset({ "E2E_EVALS_MODELS" => "openrouter/x/y" }) }
    assert_match(/"openrouter\/x\/y" is not a model the bench names: fixture\/strong/, stranger.message)
    assert_match(/alternate\/strong/, stranger.message, "the refusal names what a run MAY name: the named-only ids too")
    # The broker's flash id is a stranger since version 6: refused by name,
    # the refusal listing the direct id in its place.
    broker = assert_raises(ArgumentError) { BENCH.subset({ "E2E_EVALS_MODELS" => "fixture/retired" }) }
    assert_match(/"fixture\/retired" is not a model the bench names: .*fixture\/floor/, broker.message)
    style = assert_raises(ArgumentError) { BENCH.subset({ "E2E_EVALS_STYLES" => "claude" }) }
    assert_match(/"claude" is not a style the bench names: nexus, workflow, pack/, style.message)
    assert_raises(ArgumentError) { BENCH.subset({ "E2E_EVALS_RUNS" => "4" }) }
    assert_raises(ArgumentError) { BENCH.subset({ "E2E_EVALS_RUNS" => "0" }) }
  end

  # THE NAMED-ONLY DOOR: a named-only id enters a plan only when `E2E_EVALS_MODELS` names it — the
  # terminal-bench optional cell's door — so an unnamed run keeps the roster's four ids and never
  # pays for a frontier model; once named, the id reads its tier's bar like any roster id.
  def test_a_named_only_model_rides_a_run_that_names_it_and_never_the_roster
    assert_equal %w[fixture/strong fixture/second fixture/floor fixture/exempt],
      BENCH.models, "the roster, exact"
    assert_equal %w[fixture/strong fixture/second fixture/floor fixture/exempt
                    alternate/strong alternate/fallback alternate/floor], BENCH.nameable_models
    whole = BENCH.subset(ENV_NONE)
    assert_equal BENCH.models, whole.models
    refute whole.models_named
    BENCH.named_only.values.flatten.each { |ref| refute_includes whole.models, ref, "an unnamed run never pays for #{ref}" }

    named = BENCH.subset({ "E2E_EVALS_MODELS" => "alternate/strong" }, today: Date.new(2026, 9, 26))
    assert_equal ["alternate/strong"], named.models
    assert named.models_named
    assert_equal "2026-09-26-alternate_strong", named.label
    mixed = BENCH.subset({ "E2E_EVALS_MODELS" => "alternate/fallback, fixture/strong" })
    assert_equal %w[alternate/fallback fixture/strong], mixed.models, "a mixed list narrows to both, in the env's order"

    luna = E2E::Evals::Plan.build(CORPUS, BENCH, BENCH.subset({ "E2E_EVALS_TASKS" => "shape-linear",
                                                               "E2E_EVALS_MODELS" => "alternate/floor", "E2E_EVALS_RUNS" => "1" }))
    assert_equal ["shape-linear.alternate_floor.nexus.1"], luna.map(&:stem), "shape-linear is on both tiers: one run"
    strong_only = E2E::Evals::Corpus::Loaded.new(dir: CORPUS.dir, tasks: [CORPUS.find("shape-linear").with(tiers: ["strong"])])
    assert_empty E2E::Evals::Plan.build(strong_only, BENCH, BENCH.subset({ "E2E_EVALS_MODELS" => "alternate/floor", "E2E_EVALS_RUNS" => "1" })),
      "a named floor is off a strong-only task"
    sol = E2E::Evals::Plan.build(strong_only, BENCH, BENCH.subset({ "E2E_EVALS_MODELS" => "alternate/fallback", "E2E_EVALS_RUNS" => "1" }))
    assert_equal({ "tier" => "strong" }, BENCH.tier_fact(sol.sole.model), "a named strong model rides a strong-only task")
  end

  # The axis names words the pack's tables know (the alias TABLES are the SDK's) plus the one word
  # that is the pack itself: a row the daemon's settings would refuse at boot is refused here.
  def test_the_style_rows_are_words_the_pack_knows_plus_the_pack_word
    assert_empty BENCH.tool_styles - PACK.presets.words - [E2E::Evals::PACK_STYLE]
    assert_equal "pack", E2E::Evals::PACK_STYLE
    refute_includes PACK.presets.words, E2E::Evals::PACK_STYLE, "the pack word is no preset: it names no aliases of its own"
    assert_includes PACK.presets.preset("workflow").aliases.map { |spec| spec.fetch("name") }, "Workflow"
  end

  # THE RUN STEP'S ONE DOOR. `E2E_EVALS_CANDIDATE=<row>/<id>` loads a harness candidate — under the
  # `pack` word alone, on models the candidate's row covers, never a floor (the tier rule's bench
  # half) — and an unknown one is refused naming the candidates on file (none today). The retired
  # `E2E_EVALS_SUMMARIZE_AFTER_PRUNES` is an env like any other retired env: ignored, and no member
  # carries it. No candidate is on file: the candidate read is SUMMARIZER and the style, row and
  # whole-list refusals read WORD, both the test's own.
  def test_subset_reads_a_candidate_under_the_pack_word_on_its_own_strong_model_alone
    glm = "openrouter/z-ai/glm-5.3"
    selection = E2E::AdaptationRows.stub(:find, SUMMARIZER) do
      ADAPTATION_BENCH.subset({ "E2E_EVALS_STYLES" => "pack", "E2E_EVALS_MODELS" => glm,
                     "E2E_EVALS_CANDIDATE" => SUMMARIZER.key, "E2E_EVALS_SUMMARIZE_AFTER_PRUNES" => "1" })
    end
    assert_equal "glm-5.3/test-closing-sentence", selection.candidate.key
    assert_equal "summarizer_prompt", selection.candidate.kind
    assert_equal ["candidate glm-5.3/test-closing-sentence"], selection.doors, "the plan line's tail: the one door"
    refute_respond_to selection, :summarize_after_prunes, "no lever rides the selection"
    assert_equal [], ADAPTATION_BENCH.subset(ENV_NONE).doors
    assert_nil ADAPTATION_BENCH.subset(ENV_NONE).candidate

    unknown = assert_raises(ArgumentError) { ADAPTATION_BENCH.subset({ "E2E_EVALS_STYLES" => "pack", "E2E_EVALS_MODELS" => glm, "E2E_EVALS_CANDIDATE" => "glm-5.3/nope" }) }
    assert_equal %(no candidate "glm-5.3/nope": the candidates are none (e2e/evals/candidates/)), unknown.message, "the door stands with no candidate"
    E2E::AdaptationRows.stub(:find, WORD) do
      word = assert_raises(ArgumentError) { ADAPTATION_BENCH.subset({ "E2E_EVALS_STYLES" => "nexus", "E2E_EVALS_MODELS" => glm, "E2E_EVALS_CANDIDATE" => WORD.key }) }
      assert_match(/is read under E2E_EVALS_STYLES=pack alone, got nexus/, word.message)
      other = assert_raises(ArgumentError) { ADAPTATION_BENCH.subset({ "E2E_EVALS_STYLES" => "pack", "E2E_EVALS_MODELS" => "openrouter/moonshotai/kimi-k3", "E2E_EVALS_CANDIDATE" => WORD.key }) }
      assert_match(%r{openrouter/moonshotai/kimi-k3 resolves to row kimi-k3, not glm-5.3}, other.message)
      whole = assert_raises(ArgumentError) { ADAPTATION_BENCH.subset({ "E2E_EVALS_STYLES" => "pack", "E2E_EVALS_CANDIDATE" => WORD.key }) }
      assert_match(/resolves to row/, whole.message, "the bench's whole list carries other rows' models and the floors: refused")
    end
  end

  # A floor model is refused a candidate even where the candidate's row
  # covers it: a local row that covers the floor is written by hand, never by the bench.
  def test_a_candidate_never_reaches_a_floor_model
    floor_row = E2E::AdaptationRows::Candidate.new(row_id: "default", id: "x", kind: "lead_hints", payload: { "id" => "x", "text" => "t" }, seed: "s")
    E2E::AdaptationRows.stub(:find, floor_row) do
      refused = assert_raises(ArgumentError) do
        ADAPTATION_BENCH.subset({ "E2E_EVALS_STYLES" => "pack", "E2E_EVALS_MODELS" => "openrouter/z-ai/glm-5.3-flash", "E2E_EVALS_CANDIDATE" => "default/x" })
      end
      assert_match(/is on the floor tier \(read-only, never tuned for\)/, refused.message)
    end
    # A NAMED floor is refused the same way, where the gem's own row covers it: luna and sol resolve
    # to one row, so the row check passes on both and only the tier tells them apart.
    luna_row = E2E::AdaptationRows::Candidate.new(row_id: PACK.for("openai_api/gpt-6-luna").id, id: "x", kind: "lead_hints",
      payload: "The test's line.", seed: "s")
    E2E::AdaptationRows.stub(:find, luna_row) do
      refused = assert_raises(ArgumentError) do
        ADAPTATION_BENCH.subset({ "E2E_EVALS_STYLES" => "pack", "E2E_EVALS_MODELS" => "openai_api/gpt-6-luna", "E2E_EVALS_CANDIDATE" => luna_row.key })
      end
      assert_match(/openai_api\/gpt-6-luna is on the floor tier \(read-only, never tuned for\)/, refused.message)
      sol = ADAPTATION_BENCH.subset({ "E2E_EVALS_STYLES" => "pack", "E2E_EVALS_MODELS" => "openai_api/gpt-6.1-sol", "E2E_EVALS_CANDIDATE" => luna_row.key })
      assert_equal luna_row.key, sol.candidate.key, "the same row on a named strong model: admitted"
    end
  end

  # THE CANDIDATE'S CONFIGURATION: one daemon per (model × candidate) under
  # `pack`; its local row is the GEM ROW PLUS THE CANDIDATE of the gem
  # row's own id, so `adaptations: auto` resolves it in the gem row's
  # place; the record's `adaptations` fact names the row, `local`, its
  # words and the candidate; the digest covers the tables and the bytes
  # written. The home's compaction object is the mode (and a delegate's
  # model) alone. The candidate is SUMMARIZER, the test's own.
  def test_the_plan_writes_the_gem_row_plus_the_candidate_and_stamps_the_fact
    glm = "openrouter/z-ai/glm-5.3"
    selection = E2E::AdaptationRows.stub(:find, SUMMARIZER) do
      ADAPTATION_BENCH.subset({ "E2E_EVALS_TASKS" => "compaction-kernel-manual", "E2E_EVALS_STYLES" => "pack", "E2E_EVALS_MODELS" => glm,
                     "E2E_EVALS_CANDIDATE" => SUMMARIZER.key, "E2E_EVALS_SUMMARIZE_AFTER_PRUNES" => "2", "E2E_EVALS_RUNS" => "2" })
    end
    runs = E2E::Evals::Plan.build(CORPUS, ADAPTATION_BENCH, selection)
    assert_equal 2, runs.size
    assert_equal ["glm-5.3/test-closing-sentence"], runs.map { |run| run.candidate.key }.uniq
    refute_respond_to runs.first, :summarize_after_prunes, "no lever rides a Run"
    configuration = E2E::Evals::Plan.groups(runs).keys.sole
    assert_equal "kernel__pack__openrouter_z-ai_glm-5.3__glm-5.3-test-closing-sentence", configuration.slug
    assert_equal({ "compaction" => { "mode" => "kernel" }, "compose" => "on", "extensions" => ["rho/dev"],
                   "adaptations" => "auto", "default_model" => glm }, configuration.settings)
    assert_equal ["glm-5.3"], configuration.local_rows.keys, "the gem row's own id: auto resolves the local row in its place"
    written = YAML.safe_load(configuration.local_rows.fetch("glm-5.3"))
    assert_equal({ "format" => 1, "row" => "glm-5.3", "models" => ["z-ai/glm-5.3"], "tool_style" => ["nexus"],
                   "tool_descriptions" => [], "lead_hints" => [], "compose" => "on" },
      written.except("summarizer_prompt"), "the gem row's fields, carried whole")
    instructions = Conversations::Compaction::Summarizer::INSTRUCTIONS
    assert instructions.end_with?(ANCHOR), "the anchor is the kernel's closing line; a moved anchor re-cuts the fixture, loudly"
    assert written.fetch("summarizer_prompt").start_with?(instructions.delete_suffix(ANCHOR))
    assert written.fetch("summarizer_prompt").end_with?("#{ANCHOR} #{SENTENCE}")
    assert_equal instructions.bytesize + " #{SENTENCE}".bytesize, written.fetch("summarizer_prompt").bytesize,
      "ONE named edit of the kernel's text: the closing paragraph plus a sentence"
    loaded = CybrosAgent::ModelAdaptations.load(extra: [write_row(configuration.local_rows)]).for(glm)
    assert_equal ["glm-5.3", "local"], [loaded.id, loaded.source], "the pack loads the written row over the gem's"
    assert_equal({ "row" => "glm-5.3", "source" => "local", "tool_style" => ["nexus"], "candidate" => "glm-5.3/test-closing-sentence" },
      configuration.adaptations_fact)

    # The other two shapes of the fact: a preset word's local row, and the
    # gem row under `pack`.
    word = E2E::Evals::Configuration.for(E2E::Evals::Run.new(task: CORPUS.find("shape-linear"), model: glm, style: "workflow", index: 1))
    assert_equal({ "row" => "bench-workflow", "source" => "local", "tool_style" => ["workflow"] }, word.adaptations_fact)
    pack = E2E::Evals::Configuration.for(E2E::Evals::Run.new(task: CORPUS.find("shape-linear"), model: glm, style: "pack", index: 1))
    assert_equal({ "row" => "glm-5.3", "source" => "gem", "tool_style" => ["nexus"] }, pack.adaptations_fact)
    assert_equal "kernel__pack__openrouter_z-ai_glm-5.3", pack.slug, "no candidate: the slug of the step-3 shape"
    floor = E2E::Evals::Configuration.for(E2E::Evals::Run.new(task: CORPUS.find("shape-linear"), model: "openrouter/z-ai/glm-5.3-flash", style: "pack", index: 1))
    assert_equal({ "row" => "default", "source" => "gem", "tool_style" => ["nexus"] }, floor.adaptations_fact, "a floor resolves to default")
  end

  # THE DECLARED REFUSAL FALLBACKS, over a fixture bench (the shipped file's block is the version
  # bump's): `fallbacks: {model => ref}` is the bench's declaration, digested like every other line,
  # so a run's fallback rides its Run into its daemon configuration — one daemon per (… × fallback),
  # its settings.json writing `fallback_model`, which rho declares on the answering profile — and
  # every record stamps `fallback_model`, nil when the map names none for its model. The env only
  # NARROWS: `E2E_EVALS_FALLBACKS=off` runs the same bench with none (the control); any other word
  # is refused, and so is a map naming a model the bench does not.
  def test_the_fallbacks_map_rides_the_plan_into_the_daemons_settings_and_off_narrows_it
    opus = "alternate/strong"
    sol = "alternate/fallback"
    bench = BENCH.with(document: BENCH.document.merge("fallbacks" => { opus => sol }))
    assert_equal({ opus => sol }, bench.fallbacks)
    assert_equal sol, bench.fallback_for(opus)
    assert_nil bench.fallback_for(sol)
    env = { "E2E_EVALS_TASKS" => "shape-linear", "E2E_EVALS_MODELS" => "#{opus},#{sol}", "E2E_EVALS_RUNS" => "1" }

    selection = bench.subset(env)
    assert_equal({ opus => sol }, selection.fallbacks)
    assert_equal ["fallback #{opus} → #{sol}"], selection.doors, "the plan line names what the run declares"
    runs = E2E::Evals::Plan.build(CORPUS, bench, selection)
    assert_equal [[opus, sol], [sol, nil]], runs.map { |run| [run.model, run.fallback_model] }
    groups = E2E::Evals::Plan.groups(runs).keys
    assert_equal 2, groups.size, "one daemon's settings hold one declaration: a model with a fallback is its own configuration"
    declared, plain = groups
    assert_equal "kernel__nexus__fallback_alternate_fallback", declared.slug
    assert_equal({ "compaction" => { "mode" => "kernel" }, "compose" => "on", "extensions" => ["rho/dev"],
                   "adaptations" => "bench-nexus", "fallback_model" => sol }, declared.settings)
    assert_equal({ "fallback_model" => sol }, declared.fallback_fact)
    assert_equal "kernel__nexus", plain.slug
    refute plain.settings.key?("fallback_model")
    assert_equal({ "fallback_model" => nil }, plain.fallback_fact, "every record says what it ran under")
    # THE WORLD SERVES THE DECLARED FALLBACK TOO: the kernel refuses a `fallback_model` its account
    # cannot run (`provider_disabled`), so a group's providers are its models' AND their fallbacks'
    # — the 2026-09-27 live check's three `lane bug` records had only the model's own provider on.
    declared_runs, plain_runs = E2E::Evals::Plan.groups(runs).values
    assert_equal [opus, sol], E2E::Evals::Plan.served_models(declared_runs)
    assert_equal [sol], E2E::Evals::Plan.served_models(plain_runs)

    control = bench.subset(env.merge("E2E_EVALS_FALLBACKS" => "off"))
    assert_equal({}, control.fallbacks)
    assert_equal [], control.doors
    off = E2E::Evals::Plan.build(CORPUS, bench, control)
    assert_equal [nil, nil], off.map(&:fallback_model)
    assert_equal ["kernel__nexus"], E2E::Evals::Plan.groups(off).keys.map(&:slug), "the control: one daemon, no declaration"

    word = assert_raises(ArgumentError) { bench.subset(env.merge("E2E_EVALS_FALLBACKS" => "on")) }
    assert_equal %(E2E_EVALS_FALLBACKS takes "off" alone (the control run with no fallback), got "on"), word.message
    stranger = BENCH.with(document: BENCH.document.merge("fallbacks" => { "openrouter/x/y" => sol }))
    refused = assert_raises(ArgumentError) { stranger.subset(ENV_NONE) }
    assert_match(/fallbacks names "openrouter\/x\/y", not a model the bench names/, refused.message)
    assert_nil E2E::Evals::Run.new(task: CORPUS.find("shape-linear"), model: opus, style: "nexus", index: 1).fallback_model,
      "a Run built with none declares none"
  end

  # Every candidate applies to a row the loader accepts back: a tool_style
  # word replaces the words (12a/12b ran `workflow` ALONE), a hint or an
  # entry is appended, a summarizer recut edits the kernel's text once
  # (the files carry none: SUMMARIZER, HINT and WORD, the test's own, read
  # those kinds).
  def test_every_candidate_applies_to_a_row_the_loader_accepts
    (E2E::AdaptationRows.candidates.values + [SUMMARIZER, HINT, WORD]).each do |candidate|
      document = E2E::AdaptationRows.apply(candidate)
      loaded = CybrosAgent::ModelAdaptations.load(extra: [write_row({ candidate.row_id => YAML.dump(document) })]).row(candidate.row_id)
      assert_predicate loaded, :local?, candidate.key
      case candidate.kind
      when "tool_style" then assert_equal candidate.payload, loaded.tool_style.to_a
      when "lead_hints" then assert_equal PACK.row(candidate.row_id).hint_texts + [candidate.payload], loaded.hint_texts, "appended after the row's own"
      when "tool_descriptions" then assert_equal [candidate.payload.fetch("name")], loaded.tool_descriptions.map { |entry| entry.fetch("name") }
      when "summarizer_prompt" then assert_includes loaded.summarizer_prompt, candidate.payload.fetch("replacement")
      else flunk candidate.kind
      end
    end
    # The exact set of candidates on file — none — so that adding one is a deliberate edit of this
    # line rather than a file that silently widens what a lane can select.
    assert_equal [], E2E::AdaptationRows.candidates.keys
  end

  def write_row(rows)
    dir = Dir.mktmpdir("adaptations")
    rows.each { |id, yaml| File.write(File.join(dir, "#{id}.yml"), yaml) }
    dir
  end

  # A GEM ENTRY NAMES A CATALOG MODEL AND NEVER A FLOOR: the loader has no catalog, so each gem
  # entry is pinned here to match at least one chat model of the catalog (a dead entry is a typo),
  # and no gem row may cover a floor's reference — the grammar keeps `z-ai/glm-5.3*` out, but
  # `z-ai/glm-*` is legal and would hand the floor the strong row's texts. The negative control
  # proves the check can see that.
  def test_every_gem_entry_matches_a_chat_catalog_model_and_none_covers_a_floor
    PACK.gem_rows.each do |row|
      row.models.each do |entry|
        assert chat_catalog_references.any? { |reference| CybrosAgent::ModelPattern.specificity(entry, reference) },
          "row #{row.id}: #{entry.inspect} matches no catalog reference"
      end
    end
    assert_empty floor_offenders(PACK.gem_rows)
    assert_equal ["row glm-5.3 covers the floor's z-ai/glm-5.3-flash"],
      floor_offenders([PACK.row("glm-5.3").with(models: ["z-ai/glm-*"])]), "the negative control: a vendor-line prefix reaches the floor"
  end

  # THE TIERS RESOLVE APART: every floor model reads `default`, every strong model its own row, and
  # no strong and floor pair shares one — so the floor's row is the one the strong tier never reads.
  # The one exception is a NAMED floor: it resolves to its family's gem row, which the pack owns.
  def test_the_floors_resolve_to_default_and_the_strong_tier_to_rows_of_its_own
    assert_includes chat_catalog_references, "z-ai/glm-5.3"
    assert_equal %w[deepseek-flash z-ai/glm-5.3-flash], floor_references, "the direct lane's reference is the bare id (no vendor segment)"
    floor_rows = ADAPTATION_BENCH.tiers.fetch("floor").map { |id| PACK.for(id).id }
    strong_rows = ADAPTATION_BENCH.tiers.fetch("strong").map { |id| PACK.for(id).id }
    assert_equal ["default"], floor_rows.uniq, "a floor resolves to the default row"
    refute_includes strong_rows, "default", "a strong-tier model has its own row"
    assert_empty strong_rows & floor_rows, "no strong and floor pair shares a row"
    assert_equal ["default"], PACK.gem_rows.select(&:default?).map(&:id)
    refute_equal "default", PACK.for("openai_api/gpt-6-luna").id,
      "a NAMED floor rides its family's gem row under pack — the bench writes none for it and the candidate door refuses it; " \
      "the roster's floors stay on default"
  end

  # THE FLOOR'S ROW IS NEVER TUNED: `default` carries no text and the plain names alone.
  def test_the_floors_row_carries_no_text
    assert_equal [[], nil, [], ["nexus"]],
      [PACK.default.tool_descriptions, PACK.default.summarizer_prompt, PACK.default.lead_hints, PACK.default.tool_style],
      "the floor's row: never tuned for"
  end

  # The catalog's chat models by reference: a row naming its own `api_format` is a non-chat wire
  # (images, speech, transcription, embeddings); a chat model speaks its provider's.
  def chat_catalog_references
    @chat_catalog_references ||= CATALOG_FILES.flat_map do |path|
      YAML.safe_load(File.read(path, encoding: Encoding::UTF_8)).fetch("models")
        .reject { |_ref, row| Hash(row).key?("api_format") }.keys
    end.map { |ref| CybrosAgent::ModelPattern.reference(ref) }
  end

  def floor_references = ADAPTATION_BENCH.tiers.fetch("floor").map { |ref| CybrosAgent::ModelPattern.reference(ref) }.uniq

  # Every row among `rows` whose entries cover a floor's reference, by name.
  def floor_offenders(rows)
    rows.flat_map do |row|
      floor_references.select { |reference| row.specificity(reference) }.map { |reference| "row #{row.id} covers the floor's #{reference}" }
    end
  end

  # CANDIDATES LIVE IN THE HARNESS: each file names a gem row (its own file name), carries `{id,
  # kind, value | text | recut | entry, seed}` with the one key its kind takes, unique ids; a
  # `tool_style` value is words of the tables, a hint obeys the row's own-style rule, an entry keeps
  # the alias grammar, and a summarizer recut's anchor stands in the kernel's INSTRUCTIONS. No file
  # is on the directory; the test's own candidates, spelled as a file spells one, keep the grammar.
  def test_every_candidate_file_names_a_gem_row_and_keeps_the_candidate_grammar
    assert_equal [], CANDIDATE_FILES.map { |path| File.basename(path, ".yml") }
    summarizer = File.read(SUMMARIZER_FILE, encoding: Encoding::UTF_8)
    [SUMMARIZER, HINT, WORD].each do |candidate|
      spelled = { "id" => candidate.id, "kind" => candidate.kind, CANDIDATE_KINDS.fetch(candidate.kind) => candidate.payload, "seed" => candidate.seed }
      assert_candidate(spelled, PACK.row(candidate.row_id), summarizer, "the test's own #{candidate.key}")
    end
    CANDIDATE_FILES.each do |path|
      document = YAML.safe_load(File.read(path, encoding: Encoding::UTF_8))
      assert_equal %w[row candidates], document.keys
      row = PACK.row(document.fetch("row"))
      refute_nil row, "#{path}: not a gem row"
      assert_predicate row, :gem?
      assert_equal File.basename(path, ".yml"), row.id
      candidates = document.fetch("candidates")
      refute_empty candidates
      assert_equal candidates.map { |c| c.fetch("id") }, candidates.map { |c| c.fetch("id") }.uniq, "#{path}: an id twice"
      candidates.each { |candidate| assert_candidate(candidate, row, summarizer, path) }
    end
  end

  def assert_candidate(candidate, row, summarizer, path)
    kind = candidate.fetch("kind")
    key = CANDIDATE_KINDS.fetch(kind) { flunk "#{path}: #{candidate["id"]}: unknown kind #{kind.inspect}" }
    assert_equal %w[id kind seed] + [key], (%w[id kind seed] + [key]) & candidate.keys, "#{path}: #{candidate["id"]}: the keys of a #{kind} candidate"
    assert_empty candidate.keys - %w[id kind seed] - [key], "#{path}: #{candidate["id"]}: a key its kind does not take"
    assert_match(/\A[a-z0-9-]+\z/, candidate.fetch("id"))
    refute_empty candidate.fetch("seed")
    check = CybrosAgent::ModelAdaptations::Check.new(path)
    case kind
    when "tool_style" then check.subset(check.strings(candidate.fetch("value"), "value"), "value", PACK.presets.words)
    when "lead_hints"
      superseded = CybrosAgent::ModelAdaptations::Styles.superseded_names(row.tool_style, presets: PACK.presets)
      assert_empty candidate.fetch("text").scan(CybrosAgent::ModelAdaptations::BACKTICKED).flatten & superseded,
        "#{path}: #{candidate["id"]}: a plain word the row's styles supersede"
    when "summarizer_prompt"
      recut = candidate.fetch("recut")
      assert_equal %w[anchor replacement], recut.keys
      assert_includes summarizer, recut.fetch("anchor"), "#{path}: #{candidate["id"]}: the anchor moved; re-cut the candidate"
      assert recut.fetch("replacement").start_with?(recut.fetch("anchor")), "one named edit: the paragraph plus a sentence"
    when "tool_descriptions"
      CybrosAgent::ModelAdaptations::AliasSpec.read(check, candidate.fetch("entry"), "entry", plain: PACK.presets.plain)
    else flunk kind
    end
  end

  # THE PLAN: every selected task × the selected models ON ITS TIERS × the
  # styles × 1..runs, grouped by daemon configuration; the world's
  # patience is the sum of the deadlines plus the boot/teardown slack.
  def test_the_plan_sizes_the_world_from_the_selection
    selection = BENCH.subset({ "E2E_EVALS_TASKS" => "shape-linear", "E2E_EVALS_STYLES" => "nexus,workflow" }, today: Date.new(2026, 9, 10))
    runs = E2E::Evals::Plan.build(CORPUS, BENCH, selection)
    assert_equal 4 * 2 * 3, runs.size, "four models on both tiers × two styles × three runs"
    assert_equal [1, 2, 3], runs.first(3).map(&:index)
    assert_equal 2 * 24 * 600 + 900, E2E::Evals::Plan.journey_seconds(runs), "twice each deadline (a red holds the world for two awaits) plus the slack"
    groups = E2E::Evals::Plan.groups(runs)
    assert_equal %w[kernel__nexus kernel__workflow], groups.keys.map(&:slug)
    assert_equal({ "compaction" => { "mode" => "kernel" }, "compose" => "on", "extensions" => ["rho/dev"],
                   "adaptations" => "bench-workflow" },
      groups.keys.last.settings, "a preset word is a LOCAL row pinned by name; no tool_style is written anywhere")
    row = CybrosAgent::ModelAdaptations.load(extra: []).default
    written = YAML.safe_load(groups.keys.last.local_rows.fetch("bench-workflow"))
    assert_equal({ "format" => 1, "row" => "bench-workflow", "models" => [], "tool_style" => ["workflow"], "compose" => "on" },
      written.slice("format", "row", "models", "tool_style", "compose"), "the style's words alone, as every 12a/12b record ran")
    assert_equal [[], nil, []], written.values_at("tool_descriptions", "summarizer_prompt", "lead_hints"), "no text"
    assert_equal ["bench-nexus"], groups.keys.first.local_rows.keys, "one row per word"
    assert_equal ["nexus"], row.tool_style, "the gem's default row is what a floor runs under"
    pack = E2E::Evals::Configuration.for(E2E::Evals::Run.new(task: CORPUS.find("shape-linear"), model: "fixture/strong",
      style: E2E::Evals::PACK_STYLE, index: 1))
    assert_equal({ "compaction" => { "mode" => "kernel" }, "adaptations" => "auto", "default_model" => "fixture/strong",
                   "compose" => "on", "extensions" => ["rho/dev"] }, pack.settings,
      "pack: the SDK row for the model is the boot row, off default_model; the host daemon's home names rho-dev " \
      "(its drivers type `rho watch`, `rho say`, `rho answer`, `rho request`)")
    assert_equal({}, pack.local_rows)
    assert_equal "kernel__pack__fixture_strong", pack.slug, "one daemon per model under pack"
    assert_equal 12, groups.values.first.size

    floor_only = BENCH.subset({ "E2E_EVALS_TASKS" => "shape-linear", "E2E_EVALS_MODELS" => "fixture/exempt",
                                "E2E_EVALS_RUNS" => "1" })
    assert_equal 1, E2E::Evals::Plan.build(CORPUS, BENCH, floor_only).size
    whole_floor = BENCH.subset({ "E2E_EVALS_MODELS" => "fixture/exempt", "E2E_EVALS_RUNS" => "1" })
    assert_equal CORPUS.tasks.count { |task| task.on_tier?("floor") }, E2E::Evals::Plan.build(CORPUS, BENCH, whole_floor).size,
      "the whole corpus on the floor is every floor-tier task once"
    strong_task = CORPUS.find("shape-linear").with(tiers: ["strong"], daemon: { "compaction" => "delegate" })
    corpus = E2E::Evals::Corpus::Loaded.new(dir: CORPUS.dir, tasks: [strong_task])
    assert_empty E2E::Evals::Plan.build(corpus, BENCH, floor_only), "a floor model is off a strong-only task"
    delegate = E2E::Evals::Plan.groups(E2E::Evals::Plan.build(corpus, BENCH, BENCH.subset({ "E2E_EVALS_RUNS" => "1" })))
    assert_equal %w[delegate__nexus__fixture_strong delegate__nexus__fixture_second], delegate.keys.map(&:slug),
      "the delegate's summarizer names a model, so a delegate configuration is per model"
    assert_equal({ "mode" => "delegate", "model" => "fixture/strong" }, delegate.keys.first.settings.fetch("compaction"))
  end

  # EVERY RUN HAS A NAME OF ITS OWN (the v11 bench's shared project directory: the lane named it
  # `<task>.<style>.<n>`, so every model's run #N of a task landed in one directory under the
  # group's home): the stem the project directory and the artifact share names the model, and no
  # two runs of a plan share one.
  def test_every_run_of_the_plan_names_its_own_stem
    selection = BENCH.subset({ "E2E_EVALS_TASKS" => "workflow-loop-until-dry", "E2E_EVALS_STYLES" => "nexus,workflow" },
      today: Date.new(2026, 9, 24))
    runs = E2E::Evals::Plan.build(CORPUS, BENCH, selection)
    stems = runs.map(&:stem)
    assert_equal stems.uniq, stems, "no two runs share a stem"
    assert_equal "workflow-loop-until-dry.fixture_strong.nexus.1", runs.first.stem
    first_runs = runs.select { |run| run.index == 1 && run.style == "nexus" }
    assert_equal selection.models.size, first_runs.map(&:stem).uniq.size, "every model's run #1 has its own"
  end
end
