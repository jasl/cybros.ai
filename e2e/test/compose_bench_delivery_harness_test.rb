require_relative "executed_plan_scenarios"
require_relative "compose_bench_harness"
require "support/compose_bench/delivery"
require "support/task_bench/declared_set"
require "minitest/mock"

# WHAT COMES BACK TO THE CALLER, read off a plan and off the kernel's rows (`Delivery`): the pure
# rule over the script's own steps, and the waited head's reads and the wake's set on the rows the
# tree's kernel placed for the same plan, one set key for key — the launch's offline check that the
# rule the harness reads is the rule the kernel runs.
class ComposeBenchDeliveryHarnessTest < Minitest::Test
  include ComposeBenchHarness

  Delivery = E2E::ComposeBench::Delivery
  EXECUTED = ExecutedPlanScenarios.all.values.map { |fixture| fixture.slice("script", "params") }.freeze

  def steps(script) = Nexus::Compose::Evaluator.call(script: script).steps

  # THE PURE RULE: what no step names comes back, in placement order; a step's `results:` consume
  # what they name; a race nobody names comes back as its barrier, whose arms — every step in them,
  # at any depth — it stands for.
  def test_the_pure_rule_names_what_no_step_reads
    assert_equal %w[tool-1 model-1], Delivery.unread(steps(<<~JS))
      g.tool({ name: "bash", input: { command: "a" } });
      const b = g.tool({ name: "bash", input: { command: "b" } });
      g.model({ prompt: "Read b.", results: [b] });
    JS
    assert_equal %w[parallel-1], Delivery.unread(steps(<<~JS))
      g.parallel([
        [g.tool({ name: "bash", input: { command: "a" } }), g.model({ prompt: "a" })],
        [g.tool({ name: "bash", input: { command: "b" } }), g.model({ prompt: "b" })],
      ], { until: "any" });
    JS
    assert_equal %w[parallel-2], Delivery.unread(steps(<<~JS)), "a nested race is an arm of the race around it"
      g.parallel([
        [g.parallel([g.tool({ name: "bash", input: { command: "a" } }), g.tool({ name: "bash", input: { command: "b" } })], { until: "any" })],
        g.tool({ name: "bash", input: { command: "c" } }),
      ], { until: "any" });
    JS
  end

  def test_replay_uses_explicit_test_database_names_for_its_child
    databases = { "RAILS_TEST_APP_DB_NAME" => "delivery_test", "RAILS_TEST_CABLE_DB_NAME" => "delivery_cable_test" }
    captured = nil
    success = Data.define(:success?).new(true)
    runner = lambda do |*_command, env:, out:, **_options|
      captured = env
      out.puts JSON.generate({ "built" => false })
      success
    end

    E2E::ProcessRunner.stub(:run, runner) do
      result = Delivery.replay([{ "script" => "invalid" }],
        env: databases.merge("RAILS_ENV" => "development", "RAILS_APP_DB_NAME" => "personal_development"))
      assert_equal 1, result.comparisons.size
    end

    assert_equal "test", captured.fetch("RAILS_ENV")
    assert_equal databases, captured.slice(*databases.keys)
    refute captured.key?("RAILS_APP_DB_NAME")
    refute captured.key?("RAILS_QUEUE_DB_NAME")
    refute captured.key?("RAILS_CABLE_DB_NAME")
  end

  def test_development_database_names_cannot_authorize_a_test_replay
    env = { "RAILS_APP_DB_NAME" => "personal_development", "RAILS_CABLE_DB_NAME" => "personal_cable_development" }
    E2E::ProcessRunner.stub(:run, ->(*) { flunk "a child must not start without explicit test database names" }) do
      error = assert_raises(ArgumentError) { Delivery.replay([], env: env) }
      assert_includes error.message, "RAILS_TEST_APP_DB_NAME"
      assert_includes error.message, "RAILS_TEST_CABLE_DB_NAME"
    end
  end

  # THE KERNEL'S ROWS AGREE: every canonical script and every executed fixture's script, placed on
  # this tree's kernel waited and detached, hands the head and the wake the set the pure rule names,
  # and no plan's set outgrows what one head may read. The runner writes rows, so it runs on the
  # tree's own test database, named in the environment the suite runs in.
  def test_the_kernels_rows_deliver_what_the_pure_rule_names
    env = ENV.to_h.slice(*Delivery::DATABASES)
    skip "name this tree's test database (#{Delivery::DATABASES.join(", ")}) to read the kernel's rows" unless env.size == Delivery::DATABASES.size

    canonical = [*CANONICAL.values, *SECOND_CANONICAL.values].map { |script| { "script" => script, "params" => {} } }
    [Delivery.replay(canonical, env: env),
     Delivery.replay(EXECUTED, env: env, tool_names: E2E::TaskBench::DeclaredSet.names(style: "nexus"),
       declarations: E2E::TaskBench::DeclaredSet.function_definitions)].each do |result|
      assert result.comparisons.all?(&:built), "every plan is placed"
      assert result.agrees?, result.mismatches.map { |compared, index| "#{index}: #{compared.to_h}" }.join("\n")
      assert result.within_bound?, "#{result.distribution} against #{result.bound}"
    end
  end
end
