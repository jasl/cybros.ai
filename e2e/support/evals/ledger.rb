require_relative "bench"
require_relative "records"
require_relative "scorecard"

module E2E
  module Evals
    # The ledger groups dated labels by bench digest and displays reach, success and verified pass
    # separately — success crediting the model under test its own work, the records a declared
    # fallback served apart, the steps it served marked. A disagreement marker exposes conflicting
    # scorers without averaging them or stopping later runs. The cache column is the median pooled
    # hit rate after the first spine round; records without that series display a dash. Floor
    # models remain read-only observations. Building this table reads stored records and boots no
    # world.
    module Ledger
      FILE = "LEDGER.md".freeze
      EMPTY = "(no runs yet: `E2E_LIVE=1 bundle exec rake \"evals[<glob>,<model>]\"` writes the first)".freeze

      module_function

      def write(runs_dir, bench: Bench.read)
        text = render(runs_dir, bench: bench)
        FileUtils.mkdir_p(runs_dir)
        File.write(File.join(runs_dir, FILE), text)
        text
      end

      def render(runs_dir, bench: Bench.read)
        by_label = Records.read_all(runs_dir).reject { |_label, rows| rows.empty? }
        lines = ["# evals ledger", "", "cell = `r<reached>/<runs> s<succeeded>/<reached> p<passed>/<verified>`; " \
                                       "a `—` pass means the task has no verification, `r— s—` a family with no reach dimension " \
                                       "(the container yardsticks: task pass is the one number); " \
                                       "on a compose picture task's cell whose records carry the lane's `tier: #{Bench::FLOOR}` fact " \
                                       "`u<usable>/<reached>·x<picture>/<reached>` stands where `s` stands (its success is usable " \
                                       "generation; `x` counts the runs that also met the strong tier's picture; a floor column from " \
                                       "before the stamp keeps `s`, read on the picture); ` d<n>` counts the records classed " \
                                       "`#{Scorecard::DISAGREEMENT}` (task pass and the predicate apart: read, never a stop); " \
                                       "`s<N> (+<M> by fallback)/<reached>` counts apart the records whose refused steps the " \
                                       "answerer's declared fallback served (the model under test is credited N alone), and " \
                                       "` fb<n>` the steps it served; " \
                                       "` c<median>` the cell's median cache hit rate AFTER round 1 (the spine's rounds 2..n pooled; `c—` when no " \
                                       "record carries the per-round series; the bar is the scorecard's `#{Scorecard::CACHE_UNDER_FLOOR}`, read against " \
                                       "`limits.cache_floor_by_family`). " \
                                       "#{Scorecard::R_08}", ""]
        return "#{(lines << EMPTY).join("\n")}\n" if by_label.empty?

        sections(by_label).each do |digest, labels|
          lines << "## bench `#{digest[0, 12]}` — #{labels.join(", ")}" << ""
          lines.concat(table(labels.to_h { |label| [label, by_label.fetch(label)] }, bench))
          lines << ""
        end
        "#{lines.join("\n").rstrip}\n"
      end

      # Labels grouped by the digest their records carry, in the order the
      # labels ran (a records file mixing digests is refused where it is
      # appended and by the scorecard; here its first digest names it).
      def sections(by_label)
        by_label.group_by { |_label, rows| rows.first["bench_digest"].to_s }.transform_values { |pairs| pairs.map(&:first) }
      end

      def table(by_label, bench)
        labels = by_label.keys
        rows = by_label.values.flatten.map { |row| row.values_at("family", "task", "model", "style") }.uniq.sort
        lines = ["| family | task | model | style | #{labels.join(" | ")} |", "|#{"---|" * (4 + labels.size)}"]
        rows.each do |family, task, model, style|
          cells = labels.map do |label|
            cell(by_label.fetch(label).select { |r| r.values_at("family", "task", "model", "style") == [family, task, model, style] }, bench: bench)
          end
          lines << "| #{family} | #{task} | #{model}#{bench.tier_of(model) == Bench::FLOOR ? " (#{Bench::FLOOR}, read-only)" : ""} | " \
                   "#{style} | #{cells.join(" | ")} |"
        end
        lines
      end

      # The reach and success counts are over the records that READ them;
      # a cell that read none prints `r— s—`; a floor cell of a compose
      # picture task prints its usable count and its pictures in `s`'s
      # place (`Scorecard.usable_bar?`); the cache median (after round
      # 1) over the records carrying the per-round series, `c—` when none.
      def cell(rows, bench: Scorecard.bench_on_disk)
        return "·" if rows.empty?

        read = rows.reject { |row| row.dig("verdict", "reached").nil? }
        reached_rows = read.select { |row| row.dig("verdict", "reached") }
        reached = reached_rows.size
        succeeded = Scorecard.succeeded_term(read)
        success = Scorecard.usable_cell?(rows) ? "u#{succeeded}/#{reached}·x#{Scorecard.pictured(reached_rows)}/#{reached}" :
          "s#{succeeded}/#{reached}"
        verified = rows.reject { |row| row.dig("verdict", "task_pass").nil? }
        passed = verified.count { |row| row.dig("verdict", "task_pass") == true }
        # The class is read LIVE off each record (`Scorecard.classify`, as the
        # scorecard renders it), so a label scored before the class existed
        # shows its disagreements too; the stored `verdict.class` is history.
        apart = rows.count { |row| Scorecard.classify(row, bench: bench) == Scorecard::DISAGREEMENT }
        served = rows.sum { |row| row.dig("facts", "refusals_served").to_i }
        cache = Scorecard.median(Scorecard.cache_rates(rows))
        "#{read.empty? ? "r— s—" : "r#{reached}/#{read.size} #{success}"} " \
          "p#{verified.empty? ? "—" : "#{passed}/#{verified.size}"}#{apart.zero? ? "" : " d#{apart}"}" \
          "#{served.zero? ? "" : " fb#{served}"} c#{cache.nil? ? "—" : cache}"
      end
    end
  end
end
