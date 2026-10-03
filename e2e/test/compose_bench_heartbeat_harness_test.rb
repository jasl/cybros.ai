require_relative "compose_bench_harness"
require "support/bench_records"

# THE PER-CALL HEARTBEAT a screen's watch ticks its stall clock on: each call of a compose draw —
# the first and the repair — leaves one `calls.jsonl` line the moment it ends, naming the draw it
# belongs to (the model, the objective, the sample) and its ordinal in that draw beside its own
# facts, so a call line is tied to its draw; never a scorer's reading. Over a scripted client;
# nothing calls a provider.
class ComposeBenchHeartbeatHarnessTest < Minitest::Test
  include ComposeBenchHarness

  JOB_ENV = %w[E2E_BENCH_DIR E2E_BENCH_ARM E2E_BENCH_PROCESS].freeze

  def test_each_call_of_a_draw_beats_once_naming_its_draw_and_its_ordinal
    with_bench_dir do |dir|
      client = ScriptedClient.new(
        ->(_request) { compose_call('g.tool({ name: "bash", command: "bin/rails test" });') },
        ->(_request) { compose_call(CANONICAL.fetch("O4")) }
      )
      sample = E2E::ComposeBench::Probe.new(client: client, route: route, row: Rows.find("shipped")).sample(Objectives.find("O4"), 3)
      assert_equal "valid", sample["repaired"], "the first call was refused and the repair answered"
      beats = calls(dir)
      assert_equal [["openrouter/acme/test-model", "O4", 3, 1], ["openrouter/acme/test-model", "O4", 3, 2]],
        beats.map { |beat| beat.values_at("model", "objective", "sample", "index") }
      assert_equal [%w[with 7]] * 2, beats.map { |beat| beat.values_at("arm", "process") }
      assert_empty beats.flat_map(&:keys).uniq - E2E::BenchRecords::HEARTBEAT - %w[arm process recorded_at error_class],
        "only the call's own facts land"
    end
  end

  def test_a_call_that_raised_beats_with_its_error_class_and_its_draw
    with_bench_dir do |dir|
      client = ScriptedClient.new(->(_request) { raise NoMethodError, "undefined method 'tool_calls' for nil" })
      E2E::ComposeBench::Probe.new(client: client, route: route, row: Rows.find("shipped")).sample(Objectives.find("O2"), 1)
      assert_equal [["O2", 1, 1, "NoMethodError"]], calls(dir).map { |beat| beat.values_at("objective", "sample", "index", "error_class") }
    end
  end

  private

    def calls(dir) = File.readlines(File.join(dir, E2E::BenchRecords::CALLS), chomp: true).map { |line| JSON.parse(line) }

    # The probe reads its job's stream directory from the environment, as a screen's job sets it.
    def with_bench_dir
      saved = ENV.to_h.slice(*JOB_ENV)
      Dir.mktmpdir("compose-heartbeat") do |dir|
        ENV.update("E2E_BENCH_DIR" => dir, "E2E_BENCH_ARM" => "with", "E2E_BENCH_PROCESS" => "7")
        yield dir
      end
    ensure
      JOB_ENV.each { |key| ENV.delete(key) }
      ENV.update(saved)
    end
end
