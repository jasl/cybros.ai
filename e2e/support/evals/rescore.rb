require "json"
require "time"
require_relative "corpus"
require_relative "records"
require_relative "scorecard"
require_relative "trace"
require_relative "world_log"

module E2E
  module Evals
    # A RE-SCORE FROM THE STORED TRACE (evals fixes 2): a predicate fix — `per_file` counting
    # mentions (12a L2) — changes what a record SAYS without changing what the model DID, and the
    # artifact under `artifacts/evals/<label>/<stem>.json` holds the whole trace the lane scored
    # (the graph, the joined task rows, the feed's items, the spend, the facts, the summaries, the
    # sealed request). `expected.rb` is run over it again and ONE NEW LINE is appended per record —
    # the merge rule (`Records`: the newer line on the same key wins) reads it as the row, the old
    # line stays on disk as history — marked `rescored: true` with the time and the verdict it
    # replaced. The verification is NOT re-run (the project is gone): `task_pass` and its output
    # ride as recorded. A record whose artifact is missing is skipped by name: a fact the artifact
    # never held — a feed item the kernel did not emit then — cannot be re-scored; that cell is
    # re-RUN.
    #
    # WHAT A RE-SCORE READS: a predicate's inputs — everything `expected.rb` reads: reach, success,
    # conduct, the task's facts — are the stored trace, what the kernel served the lane through its
    # routes. The world's logs the lane copied beside the artifact (`logs/<stem>/`) may supply the
    # lane's OWN diagnostic facts — `in_flight`, the one today — read by the same pure reader the lane
    # uses live (`WorldLog.in_flight`), and never a predicate's input: not a reply, not a task row,
    # not a receipt. A predicate input the trace does not hold is a re-run.
    #
    # A re-score that changes nothing (the same verdict, reason, facts, conduct) writes
    # nothing: the verb is by task, and an unchanged cell owes the ledger no second line. A record
    # scored under another bench (its `bench_digest` is not this tree's) is refused by name: a
    # changed measurement is a new version and a new column, and re-reading an older version's runs
    # under today's predicates would write a column that belongs to neither. `force` re-scores it
    # anyway — the repair of a harness fault on the bench the record ran under, which keeps its
    # digest.
    module Rescore
      READ = %w[verdict reason facts conduct conduct_reasons efficiency].freeze

      module_function

      # The new records appended under `run_dir`, in the label's order.
      def call(run_dir, task_glob, corpus:, artifacts_dir:, bench_digest:, force: false, now: Time.now.utc)
        Records.read(run_dir).select { |record| File.fnmatch?(task_glob, record["task"].to_s) }.filter_map do |record|
          if record["bench_digest"] != bench_digest && !force
            warn "rescore: #{name_of(record)} was scored under bench #{record["bench_digest"].to_s[0, 12]}, not this tree's " \
                 "#{bench_digest[0, 12]}: re-run the cell under this bench (force only a harness fault's re-score)"
            next
          end
          artifact = artifact_of(record, artifacts_dir, File.basename(run_dir))
          if artifact.nil?
            warn "rescore: no artifact for #{name_of(record)} (#{record["artifact"]}): re-run the cell"
            next
          end
          fresh = rescored(record, corpus.find(record.fetch("task")), trace_of(record, artifact), now)
          if unchanged?(record, fresh)
            warn "rescore: #{name_of(record)} unchanged, nothing appended"
            next
          end
          Records.append(run_dir, fresh)
        end
      end

      def unchanged?(record, fresh) = READ.all? { |key| record[key] == fresh[key] }

      def name_of(record) = "#{record["task"]} #{record["model"]} #{record["style"]} ##{record["run"]}"

      # The record's own path when it exists, else the same stem under this
      # tree's artifacts dir (the records were written on another machine's
      # absolute path).
      def artifact_of(record, artifacts_dir, label)
        path = record["artifact"].to_s
        return path if !path.empty? && File.file?(path)

        local = File.join(artifacts_dir, label, File.basename(path))
        File.file?(local) ? local : nil
      end

      def trace_of(record, path)
        stored = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
        trace = Trace.new(loops: Array(record["loops"]), graph: Hash(stored["graph"]), tasks: Array(stored["tasks"]),
          events: Array(stored["events"]), spend: stored["spend"], sealed: stored["sealed_request"],
          facts: Hash(stored["facts"]).merge("summaries" => Hash(stored["summaries"])))
        with_copied_stream(record, trace, path)
      end

      # A HARNESS STOP SCORED BEFORE THE LANE READ THE STREAM: the loop's frames are read off the
      # model runner's log the lane copied beside the artifact — its window from byte 0, the copy
      # being the window — through the lane's own reader. A record with no copied log, or a log
      # holding no Solid Cable INSERT, stands as it was.
      def with_copied_stream(record, trace, path)
        return trace unless Scorecard::HARNESS_STOPS.include?(record["stopped"]) && trace.fact(:in_flight).nil? && trace.loop_id

        log = File.join(File.dirname(path), "logs", File.basename(path, ".json"), WorldLog::MODEL_RUNNER_LOG)
        read = WorldLog.in_flight(windows: [WorldLog::Window.new(name: WorldLog::MODEL_RUNNER_LOG, path: log, from: 0)],
          loop_id: trace.loop_id, stopped_at: trace.stopped_at)
        read.nil? ? trace : trace.with_facts("in_flight" => read)
      end

      # The lane's `build_record` shape over the re-run verdict: the
      # verification's columns as recorded, everything the predicate
      # answers re-read, the class re-read off the new record.
      def rescored(record, task, trace, now)
        verdict = task.expected.verdict(trace)
        facts = Hash(record["facts"])
        rescored = record.merge(
          "verdict" => { "reached" => verdict.reached, "succeeded" => verdict.succeeded,
                         "task_pass" => record.dig("verdict", "task_pass"), "class" => nil },
          "reason" => verdict.reason,
          "facts" => trace.structure_facts.merge(trace.facts.except("summaries")).merge(verdict.facts)
            .merge("verification_output" => facts["verification_output"]),
          "efficiency" => Hash(record["efficiency"]).merge(
            "compactions_survived" => (verdict.work_survived?(record.dig("verdict", "task_pass")) ? trace.compactions.size : 0)
          ),
          "conduct" => verdict.conduct_facts, "conduct_reasons" => verdict.conduct_reasons,
          "rescored" => true, "rescored_at" => now.iso8601,
          "rescored_from" => { "verdict" => record["verdict"], "reason" => record["reason"] }
        ).compact
        rescored["verdict"]["class"] = Scorecard.classify(rescored)
        rescored
      end
    end
  end
end
