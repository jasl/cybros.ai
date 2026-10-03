$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "support/screen/analysis"
require "support/screen/definition"
require "support/screen/stamp"

# THE REHEARSAL, WHOLE: `bin/screen` over the fake definition with both arms in this checkout, into a
# scratch home — Stage 0 (the bytes each tree's own bundle reads, the rates each tree's own kernel
# derives, the smoke through the real probes), the stamp, the watch as its own process, every job its
# real probe over the fake transport (a task draw reading its fixture before it hands out), then the
# last act: the deferred reports, the count, the analysis over the definition's own clauses, and the
# readout, which a rehearsal keeps in its home. No socket and no key: a fake job carries no paid
# opt-in, so `ManualClient.validate!` could never pass in one.
class ScreenRehearsalHarnessTest < Minitest::Test
  S = E2E::Screen
  E2E_DIR = File.expand_path("..", __dir__)
  ROOT = File.expand_path("..", E2E_DIR)
  FAKE = File.join(E2E_DIR, "support/fixtures/screen/fake")

  def test_the_fake_rehearsal_runs_end_to_end_and_reads_out_in_its_home
    Dir.mktmpdir("screen-rehearsal") do |scratch|
      home = File.join(scratch, "home")
      out, status = Open3.capture2e(launcher_env, Gem.ruby, "bin/screen", FAKE, "--fake", "--with", ROOT, "--without", ROOT,
        "--home", home, chdir: E2E_DIR, unsetenv_others: true)
      assert status.success?, out

      definition = S::Definition.load(FAKE)
      stamp = S::Stamp.read(home)
      assert_equal "fake", stamp.fetch("mode")
      assert_equal definition.jobs, S::Stamp.jobs(stamp)
      assert_match(/\A\h{64}\z/, stamp.fetch("rates_sha256"), "the fictional models' local rates")
      assert(stamp.keys.any? { |key| key.start_with?("smoke.cache.") }, "the smoke's cache lane was checked")

      counts = File.readlines(File.join(home, "counts.txt"), chomp: true, encoding: Encoding::UTF_8)
      assert_equal definition.jobs.size, counts.size
      assert counts.all? { |line| line.start_with?("ok ") }, counts.join("\n")
      assert_match(/ALL-DONE draws (\d+)\/\1 .* stop none/, File.read(File.join(home, "logs", "watch.log"), encoding: Encoding::UTF_8))
      refute File.exist?(File.join(home, "logs", "STOPPED"))

      machine = S::Analysis.machine_lines(File.join(home, "analysis.md"))
      assert_equal %w[REHEARSAL none], machine.values_at("verdict", "relaunch")
      readout = File.join(home, "readout", "e2e", "artifacts", "screen-readouts", definition.name)
      assert_equal %w[analysis.md cells.jsonl counts.txt stamp.txt], Dir.children(readout).sort
      refute File.exist?(File.join(ROOT, "e2e", "artifacts", "screen-readouts", definition.name)), "a rehearsal is never a record"

      definition.jobs.select { |job| job.instrument == "task" }.each do |job|
        records = File.readlines(File.join(job.path(home), "records.jsonl"), chomp: true, encoding: Encoding::UTF_8).map { |line| JSON.parse(line) }
        assert records.all? { |record| record.fetch("messages").all? { |message| message.key?("seconds") } }, job.dir
        two_step = records.select { |record| record["objective"] == "SP3A" }
        assert_equal [[2, 2, false]] * 2, two_step.map { |record| [record.fetch("messages").size, record["scored_message"], record.dig("usage", "is_byok")] },
          "#{job.dir}: the read answered from the fixture, the second message scored, the broker's spend summed"
        claims = records.select { |record| record["objective"] == "D1P" }
        assert_equal [[2, "compose_flat", true]] * 2, claims.map { |record| record.values_at("scored_message", "door_kind", "built") },
          "#{job.dir}: the fake's compose door, kinded by the task bench end to end (a panel whose chair names no reader)"
        assert records.all? { |record| record.key?("door_kind") }, "#{job.dir}: every scored draw carries its door's kind"
        calls = File.readlines(File.join(job.path(home), "calls.jsonl"), chomp: true, encoding: Encoding::UTF_8)
        assert_equal records.sum { |record| record.fetch("messages").size }, calls.size, "#{job.dir}: every call beats the stream"
      end
    end
  end

  private

    # The caller's environment less its bundle and every bench variable: the launch starts clean.
    def launcher_env
      ENV.to_h.reject { |key, _| key.start_with?("BUNDLE", "E2E_") || %w[RUBYOPT RUBYLIB].include?(key) }
    end
end
