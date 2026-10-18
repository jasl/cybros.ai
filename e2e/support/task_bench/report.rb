require "fileutils"
require "json"
require_relative "objectives"

module E2E
  module TaskBench
    # THE READOUT for the tools' lane: one table per (model × style)
    # (objective → pass count, the per-property columns beside), the
    # failures grouped by what the message did instead, one JSON artifact
    # with every sample — and the same writer for the live cross-turn
    # runs, keyed `task-mail`.
    module Report
      module_function

      def bench_dir(env = ENV)
        env["E2E_BENCH_DIR"].to_s.empty? ? File.expand_path("../../artifacts/bench", __dir__) : env["E2E_BENCH_DIR"]
      end

      # One table per (model × style × candidate): a candidate cell (the RUN step's text probes)
      # carries its key on every sample and in its file name; the baseline carries none.
      def write_offline(samples, dir: bench_dir)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "task_matrix.json"), "#{JSON.pretty_generate(samples)}\n")
        samples.group_by { |s| [s["model"], style_of(s), s["candidate"]] }.each do |(model, style, candidate), rows|
          File.write(File.join(dir, "results-task-#{slug(model)}-#{slug(style)}#{candidate ? "-#{slug(candidate)}" : ""}.md"),
            offline_markdown(model, rows, style: style, candidate: candidate))
        end
      end

      # A sample with no `style` was measured before the axis: the baseline.
      def style_of(sample) = sample["style"] || "nexus"

      def offline_markdown(model, samples, style: "nexus", candidate: nil)
        lines = ["# task bench (offline) — model `#{model}`, style `#{style}`#{candidate ? ", candidate `#{candidate}`" : ""}", "",
                 "gate 0: >= 2 tool calls in one message; T2, the control and the SP rows >= 2/3", "",
                 "| objective | pass | samples | properties | called |", "|---|---|---|---|---|"]
        Objectives::ALL.each do |objective|
          rows = samples.select { |s| s["objective"] == objective.id }
          next if rows.empty?

          passed = rows.count { |s| s["pass"] }
          lines << "| #{objective.id} #{objective.slug} | #{passed}/#{rows.length} | #{rows.length} | " \
                   "#{properties(rows)} | #{called(rows)} |"
        end
        lines << ""
        lines << "## per-sample detail"
        lines << ""
        samples.each do |s|
          lines << "- #{s["objective"]}##{s["sample"]}: #{s["pass"] ? "PASS" : "FAIL"} " \
                   "#{s.except("objective", "sample", "model", "style", "candidate", "pass", "called", "text").to_json}" \
                   "#{s["error"] ? " error: #{s["error"]}" : ""}"
        end
        "#{lines.join("\n")}\n"
      end

      # MERGES, never overwrites (Gate 3 F6): the sweep writes one model's matrix per run, so the
      # rows on disk are kept, a row with the same (objective, model, run, adaptations) is replaced
      # by the newer one, and every per-model table is regenerated from the union. `adaptations` is
      # the sweep's style row under `E2E_LIVE_ADAPTATIONS`; a baseline row carries none, as every
      # row before the knob did.
      LIVE_KEY = %w[objective model run adaptations].freeze

      def write_live(runs, dir: bench_dir)
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "task_mail.json")
        merged = merge_live(existing_live(path), runs)
        File.write(path, "#{JSON.pretty_generate(merged)}\n")
        merged.group_by { |r| r["model"] }.each do |model, rows|
          File.write(File.join(dir, "results-task-mail-#{slug(model)}.md"), live_markdown(model, rows))
        end
      end

      def existing_live(path)
        return [] unless File.file?(path)

        Array(JSON.parse(File.read(path, encoding: Encoding::UTF_8)))
      rescue JSON::ParserError
        []
      end

      # `to_h` keeps the LAST row for a repeated key: the newer wins.
      def merge_live(older, newer)
        (older + newer).to_h { |row| [row.values_at(*LIVE_KEY), row] }.values
      end

      def live_markdown(model, runs)
        lines = ["# task bench (live, through rho) — model `#{model}`", "",
                 "each objective >= 2 of 3 runs", "",
                 "| objective | run | pass | properties |", "|---|---|---|---|"]
        runs.each do |r|
          lines << "| #{r["objective"]} | #{r["run"]} | #{r["pass"] ? "PASS" : "FAIL"} | " \
                   "#{r.except("objective", "run", "model", "pass").to_json} |"
        end
        lines << ""
        runs.group_by { |r| r["objective"] }.each do |objective, rows|
          lines << "- #{objective}: #{rows.count { |r| r["pass"] }}/#{rows.length}"
        end
        "#{lines.join("\n")}\n"
      end

      def properties(rows)
        keys = rows.flat_map(&:keys).uniq - %w[objective sample model style candidate pass called text error max_output_tokens finish]
        keys.map do |key|
          values = rows.map { |s| s[key] }
          values.all? { |v| [true, false].include?(v) } ? "#{key} #{values.count(true)}/#{rows.length}" : nil
        end.compact.join("; ")
      end

      def called(rows)
        totals = rows.map { |s| s["called"] || {} }.reduce({}) { |sum, one| sum.merge(one) { |_, a, b| a + b } }
        totals.empty? ? "nothing" : totals.map { |name, n| "#{name}×#{n}" }.join(" ")
      end

      def slug(text) = text.to_s.downcase.gsub(/[^a-z0-9.]+/, "-").gsub(/\A-|-\z/, "")
    end
  end
end
