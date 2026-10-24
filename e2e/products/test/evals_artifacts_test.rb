require "test_helper"
require "support/evals"
require "tmpdir"

class EvalsArtifactsTest < Minitest::Test
  Task = Data.define(:name)

  def test_repeating_a_cell_retains_both_traces_and_logs_while_the_latest_record_wins
    Dir.mktmpdir("evals-artifacts") do |root|
      run = E2E::Evals::Run.new(task: Task.new(name: "shape-linear"), model: "fixture/strong", style: "nexus", index: 1)
      label = "rerun"
      run_dir = File.join(root, "runs", label)
      source = File.join(root, "server.log")
      first = E2E::Evals::Artifacts.new(root: root, label: label)
      old = write_attempt(first, run, run_dir, source, "first")
      retained = Dir.glob(File.join(first.directory, "**", "*")).select { |path| File.file?(path) }
        .to_h { |path| [path, File.binread(path)] }

      second = E2E::Evals::Artifacts.new(root: root, label: label)
      fresh = write_attempt(second, run, run_dir, source, "second")

      retained.each { |path, bytes| assert_equal bytes, File.binread(path), "a rerun changed #{path}" }
      refute_equal first.directory, second.directory
      assert_equal [old, fresh], File.readlines(E2E::Evals::Records.path(run_dir)).map { |line| JSON.parse(line) }
      assert_equal [fresh], E2E::Evals::Records.read(run_dir), "the scorecard still reads one logical cell"
      [old, fresh].each do |record|
        stored = JSON.parse(File.read(record.fetch("artifact")))
        assert_equal record, stored.fetch("record")
        assert_equal record.fetch("note"), stored.dig("facts", "attempt")
      end
    end
  end

  private

    def write_attempt(artifacts, run, run_dir, source, attempt)
      record = E2E::Evals::Drawing.record(note: attempt, artifact: artifacts.stem(run) + ".json")
      record["verdict"]["class"] = "lane bug"
      record["error"] = attempt
      artifacts.write(run, E2E::Evals::Trace.empty.with_facts("attempt" => attempt), record)
      File.write(source, "#{attempt}\n")
      [run.stem, "boot.world", "boot.configuration"].each do |name|
        E2E::Evals::WorldLog.copy(into: artifacts.logs(name), sources: { "nexus.server.log" => source })
      end
      [artifacts.logs(run.stem, "verifier", "reward.txt"), artifacts.logs("image.build.log"),
       artifacts.logs("image.#{run.stem}.container.log"), artifacts.logs("image.#{run.stem}.rho.log")].each do |path|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, attempt)
      end
      E2E::Evals::Records.append(run_dir, record)
    end
end
