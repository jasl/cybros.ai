require "fileutils"
require "json"
require "simple_inference"
require_relative "endpoints"
require_relative "objectives"
require_relative "styles"
require_relative "tools"

module E2E
  module ComposeBench
    # THE READOUT: one markdown table per (row × model × style) — objective →
    # first-time / after-repair, the loud and silent buckets beside, then
    # this bench's own usable, expanded, opaque and rehearsed counts — plus the gate's
    # own lines, the cell pooled over its objectives, and the failure
    # groups by error string; one JSON artifact with every sample; and the
    # local scripts and their manifest for manual inspection. Regression fixtures
    # are authored separately; paid output never writes into another project's tests.
    module Report
      GATE_RULE = "gate: >= 2/3 valid-first AND >= 2/3 correct-shape per gate objective; the control composes 0".freeze

      module_function

      def bench_dir(env = ENV)
        env["E2E_BENCH_DIR"].to_s.empty? ? File.expand_path("../../artifacts/bench", __dir__) : env["E2E_BENCH_DIR"]
      end

      # Keep paid captures beside the run's other ignored artifacts.
      def captures_dir(env = ENV)
        return File.join(bench_dir(env), "captures") if env["E2E_BENCH_CAPTURES_DIR"].to_s.empty?

        env["E2E_BENCH_CAPTURES_DIR"]
      end

      # A run REPLACES the cells it measured and keeps the rest: the matrix
      # is run one row, one model or a few objectives at a time when the
      # budget says so, and the artifact and the captures must still be the
      # whole matrix afterwards, not the last run's slice. A cell is
      # (row, model, style, candidate, objective): re-running O7b alone must
      # not delete the sibling objectives' captures, nor one style's run
      # another's, nor a candidate's run the baseline's.
      def write_all(samples, dir: bench_dir, captures: captures_dir)
        FileUtils.mkdir_p(dir)
        matrix = File.join(dir, "compose_matrix.json")
        File.write(matrix, "#{JSON.pretty_generate(merge(read(matrix), samples))}\n")
        samples.group_by { |s| [s["row"], s["model"], style_of(s), s["candidate"]] }.each do |(row, model, style, candidate), rows|
          File.write(File.join(dir, "results-#{slug(row)}-#{slug(model)}-#{slug(style)}#{candidate_segment(candidate)}.md"),
            markdown(row, model, rows, style: style, candidate: candidate))
        end
        write_captures(samples, dir: captures)
      end

      # A candidate cell's file, stem and manifest entry carry its key
      # (`glm-5.3/k6-…` → `-glm-5.3-k6-…`); the baseline carries nothing.
      def candidate_segment(candidate) = candidate ? "-#{slug(candidate)}" : ""

      # Every kept sample carries its style: one written before the axis
      # existed is the baseline's.
      def merge(existing, samples)
        cells = samples.map { |s| cell(s) }.uniq
        (existing.reject { |s| cells.include?(cell(s)) } + samples).map { |s| s.merge("style" => style_of(s)) }
          .sort_by { |s| order(s) }
      end

      def cell(sample) = [sample["row"], sample["model"], style_of(sample), sample["candidate"], sample["objective"]]

      # A sample with no `style` was measured before the axis: the baseline.
      def style_of(sample) = sample["style"] || "nexus"

      def order(sample)
        [sample["row"], sample["model"], style_rank(style_of(sample)), sample["candidate"].to_s,
         Objectives.ids.index(sample["objective"]) || Objectives.ids.length, sample["sample"]]
      end

      # The baseline first, then the presets in the pack's order, then the rest.
      def style_rank(style)
        words = Styles.words
        [words.index(style) || words.length, style]
      end

      def read(path)
        File.exist?(path) ? Array(JSON.parse(File.read(path, encoding: Encoding::UTF_8))) : []
      rescue JSON::ParserError
        []
      end

      def markdown(row, model, samples, style: "nexus", candidate: nil)
        lines = ["# compose bench — row #{row}, model `#{model}`, style `#{style}`" \
                 "#{candidate ? ", candidate `#{candidate}`" : ""}", "",
                 "samples per objective: #{samples.group_by { |s| s["objective"] }.values.map(&:length).max}; #{GATE_RULE}", "",
                 "| objective | gate | called | valid-first | exact edges | exact reads | first-time right | valid after repair | " \
                 "right after repair | loud | silent | usable | expanded right | opaque | rehearsed right |",
                 "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        Objectives::ALL.each do |objective|
          rows = samples.select { |s| s["objective"] == objective.id }
          next if rows.empty?

          lines << objective_line(objective, rows)
        end
        lines << ""
        lines.concat(verdict_lines(samples))
        lines << ""
        lines.concat(pooled_lines(samples))
        lines << ""
        lines.concat(group_lines(samples))
        lines << ""
        lines.concat(detail_lines(samples))
        "#{lines.join("\n")}\n"
      end

      def objective_line(objective, rows)
        n = rows.length
        if objective.control?
          zero = rows.count { |s| s["compose_zero"] }
          return "| #{objective.id} #{objective.slug} | control | #{tally(rows.map { |s| s["called"] })} | " \
                 "compose 0: #{zero}/#{n} | — | — | — | — | — | — | #{buckets(rows, "silent")} | — | — | — | — |"
        end
        called = rows.count { |s| s["reached"] }
        "| #{objective.id} #{objective.slug} | #{objective.gate ? "yes" : "no"} | #{called}/#{n} | " \
          "#{count(rows, "valid_first")}/#{n} | #{count(rows, "exact_edges")}/#{n} | #{count(rows, "exact_reads")}/#{n} | " \
          "#{count(rows, "first_time_right")}/#{n} | #{count(rows, "valid_after_repair")}/#{n} | " \
          "#{count(rows, "right_after_repair")}/#{n} | #{buckets(rows, "loud")} | #{buckets(rows, "silent")} | " \
          "#{count(rows, "usable")}/#{n} | #{expanded_right(rows)} | #{count(rows, "opaque")} | #{rehearsed_right(rows)} |"
      end

      # The expanded reading counts an opaque sample out: its stage's expansion is unknowable here.
      def expanded_right(rows)
        "#{rows.count { |s| s.dig("expanded", "first_time_right") == true }}/#{rows.count { |s| s["opaque"] != true }}"
      end

      # The rehearsed reading scores every first script that built, an opaque one included.
      def rehearsed_right(rows)
        "#{rows.count { |s| s.dig("rehearsed", "first_time_right") == true }}/#{count(rows, "valid_first")}"
      end

      # THE CELL POOLED, the control apart (its question is compose 0 alone): usable, the three readings
      # of first-time right, each mechanism endpoint over the first scripts that built — the
      # scripts it can be read on — and every sample's first-call finish, so an arm whose budget
      # ran out reads as that and not as its numbers.
      def pooled_lines(samples)
        rows = samples.reject { |s| Objectives.find(s["objective"]).control? }
        read = rows.select { |s| s["endpoints"] }
        rates = Endpoints::NAMES.map { |name| "#{name} #{read.count { |s| s.dig("endpoints", name) == true }}/#{read.length}" }
        finishes = samples.map { |s| finish_kind(s) }.tally
        ["## pooled over every objective but the control", "",
         "- usable: #{count(rows, "usable")}/#{rows.length}",
         "- first-time right: static #{count(rows, "first_time_right")}/#{rows.length}, " \
         "expanded #{expanded_right(rows)} (#{count(rows, "opaque")} opaque, counted out); " \
         "rehearsed #{rehearsed_right(rows)} (#{rows.count { |s| s.dig("rehearsed", "world_dependent") == true }} world-dependent)",
         "- endpoints over the #{read.length} first scripts that built: #{rates.join(", ")}",
         "- first-call finish, every sample: #{%w[length error other].map { |kind| "#{kind} #{finishes.fetch(kind, 0)}" }.join(", ")}"]
      end

      # The first call's finish in three words: its budget ran out, it failed (the call raised or the
      # provider finished on an error), or anything else.
      def finish_kind(sample)
        if exhausted?(sample)
          "length"
        elsif sample["error"] || sample["finish"] == "error"
          "error"
        else
          "other"
        end
      end

      # The gate per objective, then the two lines the freeze reads: O3 → the `until` line, O7 → the
      # nested clause.
      def verdict_lines(samples)
        lines = ["## gate"]
        Objectives::ALL.each do |objective|
          rows = samples.select { |s| s["objective"] == objective.id }
          next if rows.empty?

          lines << "- #{objective.id}: #{verdict(objective, rows)}"
        end
        lines
      end

      def verdict(objective, rows)
        n = rows.length
        return rows.count { |s| s["compose_zero"] } == n ? "PASS (composed 0)" : "FAIL (composed for one call's worth of work)" if
          objective.control?

        valid = count(rows, "valid_first")
        right = count(rows, "first_time_right")
        bar = (n * 2.0 / 3).ceil
        verdict = valid >= bar && right >= bar ? "PASS" : "FAIL"
        "#{verdict} valid-first #{valid}/#{n}, correct-shape #{right}/#{n}#{objective.gate ? "" : " (informational)"}"
      end

      def group_lines(samples)
        groups = samples.select { |s| s["group"] }.group_by { |s| s["group"] }
        return ["## failures by error string", "", "none"] if groups.empty?

        ["## failures by error string", "",
         *groups.sort_by { |_, rows| -rows.length }.map do |group, rows|
           "- #{rows.length} × `#{group}` (#{rows.map { |s| "#{s["objective"]}##{s["sample"]}" }.join(", ")})"
         end]
      end

      def detail_lines(samples)
        ["## per-sample detail", "",
         *samples.map do |s|
           verdict = if s["compose_zero"] then "compose 0"
           elsif !s["reached"] then "no compose call (#{s["error"] || s["called"].inspect}#{finish(s)})"
           elsif s["valid_first"] then valid_verdict(s)
           else "refused (#{s["loud"]}): #{s["detail"]}#{s["repaired"] ? "; repair → #{s["repaired"]}" : ""}"
           end
           "- #{s["objective"]}##{s["sample"]}: #{verdict}"
         end]
      end

      # A first script that built: exact or its silent buckets, and why this bench does not count
      # it usable when it does not.
      def valid_verdict(sample)
        shape = sample["first_time_right"] ? "exact" : "silent: #{Array(sample["silent"]).join(",")}"
        sample["unusable"] ? "valid; #{shape}; not usable: #{sample["unusable"]}" : "valid; #{shape}"
      end

      # WHAT A REAL MODEL WROTE, one file per sample, replayed by the nexus
      # suite through the real door. `composed` marks the scripts that
      # lowered clean here (built, every tool declared) — the replay
      # asserts those land; a refused script is kept beside them as
      # evidence and skipped by the replay.
      def write_captures(samples, dir: captures_dir)
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "manifest.json")
        cells = samples.map { |s| cell(s) }.uniq
        # A manifest entry's `objective` is its stem; `task` is the objective id.
        kept = read(path).reject { |entry| cells.include?(cell(entry.merge("objective" => entry["task"]))) }
        stems = kept.map { |entry| entry["objective"] }
        Dir[File.join(dir, "*.js")].each { |file| File.delete(file) unless stems.include?(File.basename(file, ".js")) }
        fresh = samples.select { |s| s["script"] }.map do |s|
          style = style_of(s)
          File.write(File.join(dir, "#{stem(s)}.js"), s["script"])
          { "objective" => stem(s), "task" => s["objective"], "row" => s["row"], "model" => s["model"],
            "style" => style, "candidate" => s["candidate"], "sample" => s["sample"], "composed" => s["valid_first"] == true,
            "params" => s["params"], "tools" => Styles.find(style).declared,
            "first_refusal" => (s["detail"] unless s["valid_first"]) }.compact
        end
        manifest = (kept + fresh).sort_by { |entry| [order(entry.merge("objective" => entry["task"])), entry["objective"]] }
        File.write(path, "#{JSON.pretty_generate(manifest)}\n")
      end

      # The capture's stem: the baseline keeps the spelling every landed
      # capture has (`o4.r-wo.<model>.<n>`, never re-named); another style's
      # carries its word before the index, a candidate's its key after the style.
      def stem(sample)
        style = style_of(sample)
        segment = style == "nexus" ? "" : ".#{slug(style)}"
        candidate = sample["candidate"] ? ".#{slug(sample["candidate"])}" : ""
        "#{sample["objective"].downcase}.#{slug(sample["row"])}.#{slug(sample["model"])}#{segment}#{candidate}.#{sample["sample"]}"
      end

      def count(rows, column) = rows.count { |s| s[column] == true }

      # An empty completion is the provider's finish fact, not a choice the
      # model made; the detail line says which — and, for an exhausted
      # output budget, the cap, so a thinking model's spent budget reads as
      # the cap and not as "no compose".
      def finish(sample)
        return "" unless sample["finish"]

        # `cap` is absent on a sample an earlier run wrote, which `merge` keeps.
        cap = sample["max_output_tokens"]
        cap_note = exhausted?(sample) && cap ? " at the #{cap}-token cap" : ""
        ", finish #{sample["finish"]}#{cap_note}"
      end

      # The gem's reading of the finish is one word on every wire (the
      # Responses family says `incomplete` and keeps the reason apart); a
      # sample an earlier run wrote carries no reading, and on the chat wire
      # it ran on `length` is the same fact.
      def exhausted?(sample)
        sample["finish_quality"] == SimpleInference::FinishQuality::OUTPUT_BUDGET_EXHAUSTED || sample["finish"] == "length"
      end

      def buckets(rows, column)
        tally = rows.flat_map { |s| Array(s[column]) }.tally
        tally.empty? ? "—" : tally.map { |name, n| "#{name}×#{n}" }.join(" ")
      end

      def tally(called)
        totals = called.compact.reduce({}) { |sum, one| sum.merge(one) { |_, a, b| a + b } }
        totals.empty? ? "nothing" : totals.map { |name, n| "#{name}×#{n}" }.join(" ")
      end

      def slug(text) = text.to_s.downcase.gsub(/[^a-z0-9.]+/, "-").gsub(/\A-|-\z/, "")
    end
  end
end
