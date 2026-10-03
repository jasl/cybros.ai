require_relative "compose_bench_harness"

# THE TEXT BENCH'S OWN READINGS of a sample's first script, beside the shared scorer's columns:
# USABLE — D4's floor bar without a run: the script built, its plan places a step, every stage
# source parses, and some placed node is not a stage the kernel fails on its own script — and the
# EXPANDED picture, each result-free stage inlined as the
# kernel will place it, which a plan holding a result-reading stage cannot have: it is opaque and
# counted out there — and read beside it by the REHEARSED reading, which runs that stage over the
# results its world would hand it. Every case runs a whole sample over a scripted client.
class ComposeBenchUsableHarnessTest < Minitest::Test
  include ComposeBenchHarness

  def test_a_script_that_builds_and_places_steps_is_usable_and_expands_to_itself
    sample = first_sample("O2", CANONICAL.fetch("O2"))
    assert sample["usable"], sample.inspect
    refute sample.key?("unusable")
    refute sample["opaque"]
    assert sample.dig("expanded", "first_time_right"), sample.inspect
    assert_equal sample["graph"], sample.dig("expanded", "graph"), "a stage-free plan expands to itself"
  end

  # The first call's bar: a repair that lands does not make the first script usable.
  def test_a_refused_script_is_not_usable_even_when_its_repair_is
    sample = first_sample("O2", 'g.tool({ name: "read", input: {} });', repair: CANONICAL.fetch("O2"))
    assert_equal "valid", sample["repaired"]
    refute sample["usable"]
    assert_equal "refused unknown_tool_name", sample["unusable"]
    refute sample.key?("expanded"), "a refused script has no plan to expand"
  end

  # The kernel refuses a script that places no step: it would have nothing to run.
  def test_a_script_that_places_nothing_is_not_usable
    sample = first_sample("O2", "const files = ['app/models/user.rb', 'app/models/team.rb'];")
    refute sample["valid_first"], sample.inspect
    refute sample["usable"]
    assert_equal "refused script_error", sample["unusable"]
    assert_equal Nexus::Compose::Evaluator::NO_STEP, sample["detail"]
  end

  # A result-free stage runs exactly as it evaluates here, so its refusal is certain: a stage body
  # that ends on a group is refused by the kernel's stage run.
  def test_a_result_free_stage_the_kernel_refuses_leaves_the_plan_unusable
    stage = <<~'JS'
      g.parallel([
        g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/user.rb" } }),
        g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/team.rb" } }),
      ]);
    JS
    sample = first_sample("O2", "g.script({ script: #{JSON.generate(stage)} });")
    assert sample["valid_first"], "the outer script builds: a stage's body is a string until it runs"
    refute sample["usable"]
    assert_equal "stage script-1 refused script_error", sample["unusable"]
  end

  # D4's bar: a stage the kernel fails on its own script is a recorded fact, not a failed plan, while
  # another placed node survives it — the kernel runs the grep and the model beside the failed
  # stage (a model-authored stage absorbs its failure).
  def test_a_result_free_stage_refused_beside_a_surviving_step_is_usable_and_recorded
    stage = <<~'JS'
      g.parallel([
        g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/team.rb" } }),
        g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/account.rb" } }),
      ]);
    JS
    sample = first_sample("O2", <<~JS)
      g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/user.rb" } });
      g.script({ script: #{JSON.generate(stage)} });
      g.model({ prompt: "Rename full_name to display_name where it is defined." });
    JS
    assert sample["usable"], sample.inspect
    refute sample.key?("unusable")
    assert_equal ["script-1 script_error"], sample["stage_refused"]
  end

  # A stage that expanded stands only through what it placed, and a race's join is the kernel's
  # barrier, not work: a wrapper around a failing stage, or a race of failing stages, reads as the
  # flat stage and the plain group do.
  def test_a_wrapper_or_a_race_of_failing_stages_is_not_usable
    wrapped = first_sample("O2", "g.script({ script: #{JSON.generate("g.script({ script: \"throw new Error('no plan');\" });")} });")
    refute wrapped["usable"], wrapped.inspect
    assert_equal "stage script-1/script-1 refused script_error", wrapped["unusable"]
    race = first_sample("O3", <<~'JS')
      g.parallel([g.script({ script: "throw new Error('a');" }), g.script({ script: "throw new Error('b');" })], { until: "any" });
    JS
    refute race["usable"], race.inspect
    assert_equal "stage script-1 refused script_error", race["unusable"]
  end

  # Every stage source parses, or the plan is not usable — whatever survives beside it.
  def test_a_stage_that_does_not_parse_fails_the_plan_beside_a_surviving_step
    sample = first_sample("O2", <<~'JS')
      g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/user.rb" } });
      g.script({ script: "g.model({ prompt: " });
    JS
    refute sample["usable"]
    assert_equal "stage script-1 refused script_syntax_error", sample["unusable"]
  end

  # A result-reading stage's body is read for its parse alone, so the kernel's word decides:
  # `script_syntax_error` means the source does not parse and fails the plan; a failure on the
  # empty results — JSON.parse on output that is not there, a `script_error` — says nothing.
  def test_a_result_reading_stage_that_does_not_parse_leaves_the_plan_unusable
    sample = first_sample("O3", <<~'JS')
      const probe = g.tool({ name: "probe_host", input: { host: "alpha" } });
      g.script({ results: [probe], script: "return results[0].output +;" });
    JS
    refute sample["usable"]
    assert_equal "stage script-1 refused script_syntax_error", sample["unusable"]
    refute sample["opaque"], "a stage the kernel fails whatever the results is not unknown"
  end

  def test_a_result_reading_stage_that_fails_only_on_data_is_usable_and_opaque
    sample = first_sample("O3", <<~'JS')
      const probe = g.tool({ name: "probe_host", input: { host: "alpha" } });
      g.script({ results: [probe], script: "const r = results[0]; return JSON.parse(r ? r.output : '{');" });
    JS
    assert sample["usable"], sample.inspect
    assert sample["opaque"]
    refute sample.key?("expanded"), "an opaque plan is counted out of the expanded reading"
    assert_equal "failed script_error", sample.dig("rehearsed", "stages", "script-1"), "rehearsed, the probe's text is no JSON"
  end

  # THE EXPANDED READING: a whole-plan wrapper is one stage node to the static reading, and the
  # plan it wraps once inlined — O7b's picture, exact.
  def test_a_whole_plan_wrapper_reads_exact_only_when_expanded
    sample = first_sample("O7b", "g.script({ script: #{JSON.generate(CANONICAL.fetch("O7b"))} });")
    assert sample["usable"], sample.inspect
    refute sample["first_time_right"], "statically one stage stands for the plan"
    refute sample["opaque"]
    assert sample.dig("expanded", "first_time_right"), sample.inspect
    assert_equal({ "whole_plan_wrapper" => true, "ungrouped_loop" => false, "authored_labels" => false, "success_filter" => false },
      sample["endpoints"], "the first two read the script as written, the last two the plan it wraps")
  end

  private

    # One sample of `objective`, its first call answered with `script` and, when the probe asks
    # for a repair, the second with `repair`.
    def first_sample(objective, script, repair: nil)
      answers = [->(_request) { compose_call(script) }]
      answers << ->(_request) { compose_call(repair) } if repair
      probe = E2E::ComposeBench::Probe.new(client: ScriptedClient.new(*answers), route: route, row: Rows.find("shipped"))
      probe.sample(Objectives.find(objective), 1)
    end
end
