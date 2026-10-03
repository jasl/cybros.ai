require "open3"
require "time"
require_relative "../provider_lanes"

module E2E
  module Screen
    # A screen's refusal: a gate that did not hold, or draws that are not the batch a stamp
    # registered — named by the sentence a reader acts on.
    Refused = Class.new(StandardError)

    # WHAT A TREE MAY NOT CHANGE UNDER A SCREEN: all of it, since a draw runs nexus, e2e, rho and the
    # SDK gem the e2e bundle loads by path — save local readouts, so a same-day relaunch is never
    # refused over the one it supersedes. The one pathspec Stage 0's clean-tree gate, the watch's
    # tree state and the analysis read.
    WATCHED = [".", ":(exclude)e2e/artifacts/screen-readouts"].freeze

    # THE ENVIRONMENT A CHILD IN A TREE STARTS FROM: the caller's, less everything that would bind
    # it to the launcher's bundle or Ruby, every bench variable, and every provider key — a child
    # gets exactly what its recipe adds.
    def self.child_env(env = ENV)
      env.to_h.reject do |key, _|
        key.start_with?("BUNDLE", "E2E_") || %w[RUBYOPT RUBYLIB].include?(key) || ProviderLanes::KEY_NAMES.value?(key)
      end
    end

    # ONE COMMAND IN A TREE whose output a reader is shown (stderr folded in), and whether it
    # succeeded; the seam a test replaces.
    COMMAND = lambda do |argv, chdir:, env: {}|
      out, status = Open3.capture2e(Screen.child_env.merge(env), *argv, chdir: chdir, unsetenv_others: true)
      [out, status.success?]
    end

    # ONE COMMAND IN A TREE whose stdout is DATA — a sha, a listing, a JSON document: stdout alone,
    # whether it succeeded, and stderr apart for a refusal to show, so a warning a child prints never
    # joins the answer. The seam a test replaces.
    CAPTURE = lambda do |argv, chdir:, env: {}|
      out, err, status = Open3.capture3(Screen.child_env.merge(env), *argv, chdir: chdir, unsetenv_others: true)
      [out, status.success?, err]
    end

    # THE TWO INSTRUMENTS a screen draws through, each a paid probe run as its own process in its
    # arm's tree: the test file the job runs, and the variable that names its objectives (the compose
    # bench also reads its row). A closed set: a job's environment is one of these two recipes.
    Instrument = Data.define(:id, :test, :objectives_env)
    INSTRUMENTS = {
      "compose" => Instrument.new(id: "compose", test: "test/compose_matrix_probe_test.rb", objectives_env: "E2E_BENCH_OBJECTIVES"),
      "task" => Instrument.new(id: "task", test: "test/task_matrix_probe_test.rb", objectives_env: "E2E_TASK_OBJECTIVES"),
    }.freeze

    # ONE JOB: one probe process drawing `n` samples (from index `sample_first`) of each objective for
    # one model, in one arm, into its own directory (`dir`, relative to the screen's home). `lane` is
    # the model's provider — what the launch's in-flight caps and the cache key are counted by;
    # `row` is the compose bench's text row (none for the task probe). Named `Job`, never `Process`:
    # inside `E2E::Screen` a constant of that name would shadow `::Process.spawn` and `.kill`.
    Job = Data.define(:index, :arm, :instrument, :model, :objectives, :n, :sample_first, :dir, :lane, :row, :style) do
      # The stamp's job table is the registered shape the analysis reads: one line per job.
      def self.from_stamp_line(index, line)
        arm, instrument, model, *pairs = line.split
        fields = pairs.to_h { |pair| pair.split("=", 2) }
        new(index: Integer(index), arm: arm, instrument: instrument, model: model,
          objectives: fields.fetch("objectives").split(","), n: Integer(fields.fetch("n")),
          sample_first: Integer(fields.fetch("first")), dir: fields.fetch("dir"), lane: fields.fetch("lane"),
          row: (fields.fetch("row") unless fields.fetch("row") == "-"), style: fields.fetch("style"))
      end

      def stamp_line
        "#{arm} #{instrument} #{model} objectives=#{objectives.join(",")} n=#{n} first=#{sample_first} " \
          "dir=#{dir} lane=#{lane} row=#{row || "-"} style=#{style}"
      end

      def planned = objectives.size * n
      def samples = (sample_first...(sample_first + n)).to_a
      def path(home) = File.join(home, dir)
      def slug = model.tr("/", "_")
      def test = INSTRUMENTS.fetch(instrument).test

      # THE JOB'S ENVIRONMENT, exactly the bench variables its probe reads and nothing else of the
      # launcher's: the provider key is added by the launcher for a paid job alone, and so is the
      # paid gate's opt-in (`E2E_LIVE=1 RAILS_ENV=development`) — a fake job never carries it, so no
      # fake job could pass `ManualClient.validate!` whatever it drew through. BLIND always — the
      # probe prints no outcome and defers its report to the launch's last act — and the cache key
      # per (screen, arm, lane), so two arms never share a provider's cache entry.
      def env(home:, screen:, client:, max_output_tokens:)
        {
          **(client == "real" ? { "E2E_LIVE" => "1", "RAILS_ENV" => "development" } : {}),
          "E2E_BENCH_MODELS" => model,
          INSTRUMENTS.fetch(instrument).objectives_env => objectives.join(","),
          "E2E_BENCH_ROWS" => row,
          "E2E_BENCH_SAMPLES" => n.to_s, "E2E_BENCH_SAMPLE_FIRST" => sample_first.to_s,
          "E2E_BENCH_MAX_OUTPUT_TOKENS" => max_output_tokens.to_s, "E2E_BENCH_STYLES" => style,
          "E2E_BENCH_DIR" => path(home), "E2E_BENCH_CAPTURES_DIR" => File.join(path(home), "captures"),
          "E2E_BENCH_ARM" => arm, "E2E_BENCH_PROCESS" => index.to_s, "E2E_BENCH_BLIND" => "1",
          "E2E_BENCH_CACHE_KEY" => "#{screen}/#{arm}/#{lane}", "E2E_BENCH_CLIENT" => client,
        }.compact
      end

      # THE COUNT, per job after ALL-DONE: exactly the registered draws — every objective at every
      # index once, the job's own model, arm and process, nothing recorded before the launch. Each
      # problem is a sentence; none is the count holding.
      def count_problems(records, launched_at:)
        by_objective = records.group_by { |record| record["objective"] }
        [
          ("#{records.size} records of #{planned}" unless records.size == planned),
          *objectives.filter_map do |objective|
            indexes = Array(by_objective[objective]).map { |record| record["sample"] }.sort
            "#{objective} holds samples #{indexes.inspect}, not #{samples.inspect}" unless indexes == samples
          end,
          *(by_objective.keys - objectives).map { |objective| "#{objective.inspect} is not one of the job's objectives" },
          *strays(records),
          ("#{records.count { |record| early?(record, launched_at) }} records before launched_at" if records.any? { |record| early?(record, launched_at) }),
        ].compact
      end

      private

        def strays(records)
          wrong = records.reject do |record|
            record["model"] == model && record["arm"] == arm && record["process"] == index.to_s && (record["style"] || style) == style
          end
          wrong.empty? ? [] : ["#{wrong.size} records of another model, arm, process or style"]
        end

        def early?(record, launched_at) = Time.iso8601(record.fetch("recorded_at")) < launched_at
    end
  end
end
