require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "evals_drawings"
require "tmpdir"
require "json"

# A RE-SCORE FROM THE STORED TRACE, PINNED (evals fixes 2): `Rescore.call`
# reads a label's records, rebuilds each run's trace from the artifact it
# points at, runs the task's `expected.rb` again and APPENDS one new line
# per record — `rescored: true`, the verdict it replaced kept beside it —
# so the merge rule reads the new line as the row and the old stays as
# history; the verification's columns ride as recorded; a record whose
# artifact is gone is skipped by name. Pure Ruby: nothing boots.
class EvalsRescoreTest < Minitest::Test
  include EvalsFixtureBench
  D = E2E::Evals::Drawing
  W = EvalsDrawings
  R = E2E::Evals::Records
  BENCH = EvalsFixtureBench.read
  CORPUS = E2E::Evals::Corpus.load(canary: BENCH.canary)
  TASK = "task-fan-five".freeze
  # The drawn records' digest: the tree these re-scores read under.
  DIGEST = "d" * 64
  FILES = %w[a b c d e].freeze

  def test_a_record_is_rescored_from_its_artifact_as_a_new_line_the_merge_reads_first
    Dir.mktmpdir("evals-rescore") do |root|
      label = "2026-09-11-12a-glm-task"
      run_dir = File.join(root, "runs", label)
      artifacts = File.join(root, "artifacts")
      # A fan of five whose every prompt spells its file twice: the old
      # `per_file` read 2 per file ("a second task for …"), the fixed one 1.
      tasks = FILES.each_with_index.map do |f, i|
        D.tool("r1t#{i}", "task", after: ["r1"], input: { "prompt" => "Review lib/#{f}.rb; answer `lib/#{f}.rb — <token>`", "wait" => true })
      end
      old = D.record(task: TASK, family: "task", model: "fixture/strong", run: 2, reached: true, succeeded: false, task_pass: nil,
        reason: "a second task for a.rb, b.rb, c.rb, d.rb, e.rb", facts: { "round_errors" => {}, "rounds_settled" => 2, "reply" => W::FIVE_REPLY,
                                                                       "per_file" => FILES.to_h { |f| ["#{f}.rb", 2] } },
        efficiency: { "rounds" => 2, "calls" => 5, "cost_amount" => "0.01", "cost_unit" => "USD", "compactions" => {}, "compactions_survived" => 0 },
        artifact: "/elsewhere/artifacts/evals/#{label}/#{TASK}.fixture_strong.nexus.2.json")
      old["verdict"]["class"] = E2E::Evals::Scorecard.classify(old)
      R.append(run_dir, old)
      FileUtils.mkdir_p(File.join(artifacts, label))
      File.write(File.join(artifacts, label, File.basename(old["artifact"])), JSON.generate({
        "record" => old, "graph" => W::FIVE_GRAPH, "tasks" => tasks + D.rounds_of(W::FIVE_GRAPH), "events" => [],
        "spend" => { "cost_amount" => "0.01", "cost_unit" => "USD" }, "facts" => { "reply" => W::FIVE_REPLY, "style" => "nexus", "model" => "fixture/strong" },
        "summaries" => {}, "sealed_request" => nil,
      }))

      written = E2E::Evals::Rescore.call(run_dir, "task-fan-*", corpus: CORPUS, artifacts_dir: artifacts, bench_digest: DIGEST,
        now: Time.utc(2026, 9, 11, 12))
      assert_equal 1, written.size
      rescored = written.first
      assert_equal true, rescored["rescored"]
      assert_equal "2026-09-11T12:00:00Z", rescored["rescored_at"]
      assert_equal({ "reached" => true, "succeeded" => true, "task_pass" => nil, "class" => nil }, rescored["verdict"])
      assert_nil rescored["reason"]
      assert_equal(FILES.to_h { |f| ["#{f}.rb", 1] }, rescored.dig("facts", "per_file"), "the fixed predicate's column")
      assert_equal 5, rescored.dig("facts", "task_calls_in_first_message")
      assert_equal old["verdict"], rescored.dig("rescored_from", "verdict"), "the verdict it replaced rides beside it"
      assert_equal "a second task for a.rb, b.rb, c.rb, d.rb, e.rb", rescored.dig("rescored_from", "reason")
      assert_equal old["efficiency"].merge("compactions_survived" => 0), rescored["efficiency"], "the spend as recorded"
      assert_equal "0.01", rescored.dig("efficiency", "cost_amount")
      assert_equal old["bench_digest"], rescored["bench_digest"], "the trace ran under the label's digest"

      assert_equal 2, File.readlines(R.path(run_dir)).size, "appended, never edited"
      merged = R.read(run_dir)
      assert_equal 1, merged.size
      assert_equal true, merged.first["rescored"], "the newer line wins on the key"
      assert_equal true, merged.first.dig("verdict", "succeeded")
    end
  end

  def test_an_unchanged_rescore_appends_nothing
    Dir.mktmpdir("evals-rescore") do |root|
      label = "2026-09-11-same"
      run_dir = File.join(root, "runs", label)
      artifacts = File.join(root, "artifacts")
      # A fan of five whose prompts name each file once: the old and the new
      # `per_file` agree, and the record already says what the trace says.
      trace = D.trace(W::FIVE_GRAPH, W::FIVE_TASKS, [], facts: { "reply" => W::FIVE_REPLY, "style" => "nexus" })
      base = D.record(task: TASK, family: "task", run: 1, task_pass: nil, artifact: "/x/#{label}/#{TASK}.fixture_strong.nexus.1.json")
      old = E2E::Evals::Rescore.rescored(base, CORPUS.find(TASK), trace, Time.now.utc).except("rescored", "rescored_at", "rescored_from")
      assert_equal true, old.dig("verdict", "succeeded")
      R.append(run_dir, old)
      FileUtils.mkdir_p(File.join(artifacts, label))
      File.write(File.join(artifacts, label, File.basename(old["artifact"])), JSON.generate({
        "record" => old, "graph" => W::FIVE_GRAPH, "tasks" => W::FIVE_TASKS + D.rounds_of(W::FIVE_GRAPH), "events" => [],
        "spend" => nil, "facts" => { "reply" => W::FIVE_REPLY, "style" => "nexus" }, "summaries" => {}, "sealed_request" => nil,
      }))
      _out, err = capture_io do
        assert_empty E2E::Evals::Rescore.call(run_dir, TASK, corpus: CORPUS, artifacts_dir: artifacts, bench_digest: DIGEST)
      end
      assert_match(/rescore: task-fan-five .* unchanged, nothing appended/, err)
      assert_equal 1, File.readlines(R.path(run_dir)).size
    end
  end

  def test_a_record_whose_artifact_is_gone_is_skipped_by_name_and_the_glob_narrows
    Dir.mktmpdir("evals-rescore") do |root|
      run_dir = File.join(root, "runs", "2026-09-11-x")
      R.append(run_dir, D.record(task: TASK, family: "task", run: 1, artifact: "/gone/#{TASK}.m.nexus.1.json"))
      R.append(run_dir, D.record(task: "shape-linear", run: 1, artifact: "/gone/shape-linear.m.nexus.1.json"))
      _out, err = capture_io do
        assert_empty E2E::Evals::Rescore.call(run_dir, "task-*", corpus: CORPUS, artifacts_dir: File.join(root, "artifacts"),
          bench_digest: DIGEST)
      end
      assert_match(/rescore: no artifact for task-fan-five fixture\/strong nexus #1 .*: re-run the cell/, err)
      refute_match(/shape-linear/, err, "the glob narrows to the task")
      assert_equal 2, File.readlines(R.path(run_dir)).size, "nothing appended"
    end
  end

  # A STOPPED RECORD'S STREAM, READ OFF THE COPIED LOG: a record whose run the harness stopped
  # before any round settled, scored before the lane read the stream, carries no `in_flight` fact —
  # the one lane diagnostic a re-score may take from the world's logs beside the artifact
  # (`logs/<stem>/`), through the reader the lane uses live. A live stream moves the class to the
  # model's; a record with no copied log reads as it did and appends nothing.
  def test_a_stopped_records_stream_is_read_off_the_copied_log_when_the_artifact_holds_no_in_flight_fact
    task = "compose-background-suite"
    graph = D.graph([D.n("r1", "model_task", status: "running")], [])
    events = [D.event("turn_status", { "agent_loop_public_id" => "loop-1", "loop_status" => "canceling" })
      .merge("occurred_at" => "2026-09-24T19:36:44.850Z")]
    facts = { "style" => "nexus", "model" => "fixture/strong" }
    loops = [{ "id" => "loop-1", "status" => "canceling" }]
    [true, false].each do |copied|
      Dir.mktmpdir("evals-rescore") do |root|
        label = "2026-09-25-stopped"
        run_dir = File.join(root, "runs", label)
        artifacts = File.join(root, "artifacts")
        stem = "#{task}.fixture_strong.nexus.3"
        base = D.record(task: task, family: "compose", run: 3, reached: false, succeeded: nil, task_pass: nil, stopped: "deadline",
          loops: loops, artifact: "/x/#{label}/#{stem}.json")
        old = E2E::Evals::Rescore.rescored(base, CORPUS.find(task), D.trace(graph, [], events, facts: facts, loops: loops), Time.now.utc)
          .except("rescored", "rescored_at", "rescored_from")
        assert_equal E2E::Evals::Scorecard::LANE_BUG, old.dig("verdict", "class"), "nothing settled and no stream read"
        R.append(run_dir, old)
        FileUtils.mkdir_p(File.join(artifacts, label, "logs", stem))
        File.write(File.join(artifacts, label, "#{stem}.json"), JSON.generate({
          "record" => old, "graph" => graph, "tasks" => D.rounds_of(graph), "events" => events, "spend" => nil,
          "facts" => facts, "summaries" => {}, "sealed_request" => nil,
        }))
        if copied
          File.write(File.join(artifacts, label, "logs", stem, E2E::Evals::WorldLog::MODEL_RUNNER_LOG),
            cable_delta("2026-09-24 19:36:20.000000") + cable_delta("2026-09-24 19:36:21.960021"))
        end

        written = nil
        capture_io do
          written = E2E::Evals::Rescore.call(run_dir, task, corpus: CORPUS, artifacts_dir: artifacts, bench_digest: DIGEST)
        end
        if copied
          assert_equal 1, written.size
          assert_equal E2E::Evals::Scorecard::MODEL_CONDUCT, written.first.dig("verdict", "class")
          assert_equal [2, 22.9], written.first.dig("facts", "in_flight").values_at("frames", "last_frame_age_s")
          assert_equal 2, File.readlines(R.path(run_dir)).size
        else
          assert_empty written, "no copied log: the record reads as it did"
          assert_equal 1, File.readlines(R.path(run_dir)).size
        end
      end
    end
  end

  # A RECORD FROM ANOTHER BENCH is never re-scored in place: a changed measurement is a new version
  # and a new column, so re-reading an older version's runs under today's predicates would write a
  # column that belongs to neither. Refused by name; `force` is the re-score of a harness fault on
  # the bench the record ran under.
  def test_a_record_scored_under_another_bench_is_refused_unless_forced
    Dir.mktmpdir("evals-rescore") do |root|
      label = "2026-09-11-older"
      run_dir = File.join(root, "runs", label)
      artifacts = File.join(root, "artifacts")
      tasks = FILES.each_with_index.map do |f, i|
        D.tool("r1t#{i}", "task", after: ["r1"], input: { "prompt" => "Review lib/#{f}.rb", "wait" => true })
      end
      old = D.record(task: TASK, family: "task", run: 1, succeeded: false, reason: "stale", bench_digest: "e" * 64,
        artifact: "/x/#{label}/#{TASK}.fixture_strong.nexus.1.json")
      R.append(run_dir, old)
      FileUtils.mkdir_p(File.join(artifacts, label))
      File.write(File.join(artifacts, label, File.basename(old["artifact"])), JSON.generate({
        "record" => old, "graph" => W::FIVE_GRAPH, "tasks" => tasks + D.rounds_of(W::FIVE_GRAPH), "events" => [],
        "spend" => nil, "facts" => { "reply" => W::FIVE_REPLY, "style" => "nexus" }, "summaries" => {}, "sealed_request" => nil,
      }))
      _out, err = capture_io do
        assert_empty E2E::Evals::Rescore.call(run_dir, TASK, corpus: CORPUS, artifacts_dir: artifacts, bench_digest: DIGEST)
      end
      assert_match(/rescore: task-fan-five .* #1 was scored under bench eeeeeeeeeeee, not this tree's dddddddddddd/, err)
      assert_equal 1, File.readlines(R.path(run_dir)).size, "nothing appended"

      forced = E2E::Evals::Rescore.call(run_dir, TASK, corpus: CORPUS, artifacts_dir: artifacts, bench_digest: DIGEST, force: true)
      assert_equal 1, forced.size
      assert_equal "e" * 64, forced.first["bench_digest"], "a forced re-score stays in the column it ran under"
    end
  end

  private

    # One reasoning delta of loop-1's `r1` as the model runner's Rails log carries it.
    def cable_delta(created_at)
      payload = JSON.generate("event" => { "type" => "reasoning_delta", "agent_loop_public_id" => "loop-1", "task_key" => "r1" })
      "INSERT INTO \"solid_cable_messages\" (\"channel\",\"channel_hash\",\"created_at\",\"payload\") VALUES " \
        "('\\x#{"agent_api:v1:conversation:c-1:transcript".unpack1("H*")}', 5260421471401520114, '#{created_at}', " \
        "'\\x#{payload.unpack1("H*")}') ON CONFLICT  DO NOTHING RETURNING \"id\"\n"
    end
end
