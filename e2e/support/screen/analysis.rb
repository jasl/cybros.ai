require "bigdecimal"
require_relative "../bench_spend"
require_relative "clause"
require_relative "figures"
require_relative "records"
require_relative "stamp"
require_relative "stats"
require_relative "stop"
require_relative "watch"

module E2E
  module Screen
    # THE SCREEN'S LAST ACT, AFTER EVERY JOB IS DONE: read the batch the stamp registered — its job
    # table, the one every reader after the stamp reads — refuse to decide on anything else, and
    # write `analysis.md` into the screen's home with the stamp as its header, every clause with its
    # verdict, the cost per (model, arm) and the machine lines the launch reads. A STOPPED batch
    # (`Stop`) decides nothing: its analysis writes the stop in place of a verdict — the one relaunch
    # owed, or NOT-LANDED for a stop by hand that named no fault — over the draws that landed. `run`
    # answers the file's path, or nil when it refused (the reason on `out`).
    #
    # The DEFINITION is the screen's (`Definition`: its `name`, `dir`, `sha256` and job table
    # `jobs`, each a `Job`). The screen's CLAUSES are its definition's `clauses.rb`, read as a module
    # body answering:
    #   kernel_finding(draws) → [evidence]   a finding owes a fix and the relaunch; no clause is read
    #   clauses(draws)        → [Clause]
    #   verdict(clauses)      → Verdict      the screen's own outcome words
    #   reads(draws)          → [line]       printed, never deciding
    #   figures(draws, jobs)  → [Figure]     a dry run's registered figures at the registered n
    #   stops(figures)        → [reason]     a dry run's launch stops
    module Analysis
      FILE = "analysis.md".freeze
      CLAUSES = "clauses.rb".freeze
      TREES = %w[with without].freeze
      KERNEL_FINDING = "KERNEL-FINDING".freeze
      RELAUNCH = "RELAUNCH".freeze
      STOPPED = "STOPPED".freeze
      # A stop by hand that named no fault: the candidate did not land, and no relaunch is owed.
      HAND_STOPPED = "NOT-LANDED".freeze
      MACHINE = "## Machine lines (the launch reads them)".freeze

      Verdict = Data.define(:name, :text)
      # What the batch decided: the verdict and relaunch class the machine lines carry, and its section.
      Decision = Data.define(:verdict, :relaunch, :lines)

      module_function

      def run(definition, home, stamp: nil, clauses: nil, price: nil, out: $stderr)
        unless File.file?(Stamp.path(home))
          raise Refused, "no stamp at #{Stamp.path(home)}: the batch was not launched by the screen"
        end

        text = report(definition, home, stamp || Stamp.read(home), clauses || clauses_of(definition.dir), price || BenchSpend.pricer(home))
        path = File.join(home, FILE)
        File.write(path, text, encoding: "UTF-8")
        path
      rescue Refused => refusal
        out.puts("#{definition.name}: refused, nothing decided — #{refusal.message}")
        nil
      end

      # THE DRY RUN, before any paid draw: every clause's mechanics over a pair's records (read, never
      # deciding), the registered figures at the registered n and the stops they raise. No stamp is
      # read; a pair with a harness fault is no pair.
      def dry(definition, pair_dir, clauses: nil)
        set = clauses || clauses_of(definition.dir)
        draws = Records.pair(pair_dir)
        raise Refused, "no records under #{pair_dir}" if draws.empty?

        faults = draws.select { |draw| Records.fault?(draw) }
        raise Refused, "a harness fault in the pair: #{faults.first(3).map { |draw| Records.id(draw) }.join("; ")}" unless faults.empty?

        figures = set.figures(draws, definition.jobs)
        Figures.new(clauses: set.clauses(draws), finding: set.kernel_finding(draws), figures: figures, stops: set.stops(figures))
      end

      # THE MACHINE LINES of a written analysis, as `key => value`: only the section's own block,
      # since the stamp at the head carries `key=value` lines of its own. The screen's ledger reads
      # them (`Readout.latest`), so a file without them is refused by name.
      def machine_lines(path)
        block = File.read(path, encoding: "UTF-8")[/#{Regexp.escape(MACHINE)}.*?```text\n(.*?)```/m, 1]
        raise Refused, "#{path} carries no machine lines" unless block

        block.lines(chomp: true).to_h { |line| line.split("=", 2) }
      end

      # The definition's clauses, evaluated as the body of a module of their own, so a screen's
      # constants and helpers never leak into another's.
      def clauses_of(dir)
        path = File.join(dir, CLAUSES)
        Module.new.tap { |set| set.module_eval(File.read(path, encoding: "UTF-8"), path) }
      end

      def report(definition, home, stamp, set, price)
        unless stamped(stamp, "definition_sha256") == definition.sha256
          raise Refused, "the stamp registered another definition (#{stamped(stamp, "definition_sha256")[0, 12]}, not #{definition.sha256[0, 12]})"
        end

        jobs = Stamp.jobs(stamp)
        stop = Stop.reason(home)
        draws, decided = stop ? [Records.landed(jobs, home), stopped(stop)] : decide(home, stamp, jobs, set)
        [*header(definition, home), *decided.lines, *quality(draws), *cost(draws, price), *machine(decided, definition, home)].join("\n")
      end

      # The whole registered batch, over unmoved trees, and what it decided.
      def decide(home, stamp, jobs, set)
        TREES.each do |tree|
          unmoved!(tree, stamped(stamp, "tree.#{tree}.root"), stamped(stamp, "head.#{tree}"), stamped(stamp, "tree.#{tree}.state"))
        end
        draws = Records.load(jobs, home)
        Records.check!(draws, jobs: jobs, launched_at: stamped(stamp, "launched_at"))
        [draws, decision(draws, set, WatchRules::Params.from_stamp(stamp).lost_rule)]
      end

      def stamped(stamp, key) = stamp.fetch(key) { raise Refused, "the stamp has no #{key} line" }

      # The tree as the launch stamped it (`Watch.tree_state`: its HEAD, its status over everything a
      # screen watches, the builder); a re-read under a later tree is a second column, never the
      # verdict.
      def unmoved!(tree, root, head, state)
        unless Watch.tree_state(root) == state
          now = IO.popen(["git", "-C", root, "rev-parse", "HEAD"], err: File::NULL, &:read).strip
          dirty = IO.popen(["git", "-C", root, "status", "--porcelain", "--", *WATCHED], err: File::NULL, &:read).lines.map(&:strip)
          raise Refused, "the #{tree} tree moved since the launch: launched at #{head[0, 12]}, now #{now[0, 12]}; " \
                         "uncommitted: #{dirty.empty? ? "none" : dirty.first(6).join(", ")}"
        end
      end

      def header(definition, home)
        ["# #{definition.name} — analysis", "", "## Provenance (the stamp is the header)", "",
         "```text", File.read(Stamp.path(home), encoding: "UTF-8").rstrip, "```", ""]
      end

      # A stop owes the one relaunch — its class is the machine line's — unless it was a stop by hand
      # that named no fault, which reads NOT-LANDED; either way no clause is read.
      def stopped(reason)
        if WatchRules.relaunch_owed?(reason)
          Decision.new(verdict: STOPPED, relaunch: Stop.kind(reason),
            lines: ["## STOPPED — #{reason}", "", "The one whole relaunch is owed under a new stamp; no clause is read.", ""])
        else
          Decision.new(verdict: HAND_STOPPED, relaunch: "none",
            lines: ["## NOT LANDED — stopped by hand: #{reason}", "", "No clause is read, and no relaunch is owed.", ""])
        end
      end

      # A KERNEL FINDING owes a fix and the relaunch, and lost draws over the floor (`lost`, the
      # stamp's registered rule) owe the relaunch: either reads no clause. Otherwise every clause is
      # read and the screen's verdict is written.
      def decision(draws, set, lost)
        finding = set.kernel_finding(draws)
        over = Records.over_lost(draws, rule: lost)
        if finding.any?
          Decision.new(verdict: KERNEL_FINDING, relaunch: "kernel-finding",
            lines: ["## KERNEL FINDING — fix, then the one relaunch under a new stamp; no clause is read", "", *finding.map { |line| "- #{line}" }, ""])
        elsif over.any?
          Decision.new(verdict: RELAUNCH, relaunch: over.map { |cell| "lost #{cell.model}/#{cell.arm} #{cell.lost}/#{cell.draws}" }.join("; "),
            lines: ["## RELAUNCH — lost draws over the floor (more than #{format("%g", 100 * lost.share)} % and at least " \
                    "#{format("%g", lost.draws)} of a (model, arm)); no clause is read", "",
                    *over.map { |cell| "- #{cell.model} #{cell.arm}: #{cell.lost} lost of #{cell.draws}" }, ""])
        else
          clauses = set.clauses(draws)
          verdict = set.verdict(clauses)
          Decision.new(verdict: verdict.name, relaunch: "none",
            lines: ["## Verdict: #{verdict.name}", "", verdict.text, "", "## Clauses", "", *clauses.map { |clause| "- #{clause.line}" }, "",
                    "## Reads (printed, never deciding)", "", *set.reads(draws).map { |line| "- #{line}" }, ""])
        end
      end

      def quality(draws)
        rows = by_model_arm(draws).map do |(model, arm), cell|
          "| #{model} | #{arm} | #{cell.length} | #{cell.count { |draw| Records.lost?(draw) }} | #{cell.sum { |draw| Records.retries(draw) }} |"
        end
        ["## Lost draws and retries per (model, arm)", "", "| model | arm | draws | lost | retries |", "|---|---|---|---|---|", *rows, ""]
      end

      # Every draw priced whole — its every call — by the launch's pricer, summed per (model, arm).
      def cost(draws, price)
        rows = by_model_arm(draws).map do |(model, arm), cell|
          usages = cell.flat_map { |draw| Records.usages(draw) }
          tokens = Records::TOKENS.map { |name| usages.sum { |usage| usage[name].to_i } }
          total = cell.sum(BigDecimal("0")) { |draw| price.call(draw) }
          "| #{model} | #{arm} | #{cell.length} | #{cell.sum { |draw| Records.calls(draw) }} | #{tokens.join(" | ")} | $#{total.round(4).to_s("F")} |"
        end
        ["## Cost per (model, arm)", "", "| model | arm | draws | calls | input | output | cache read | cache write | $ |",
         "|---|---|---|---|---|---|---|---|---|", *rows, ""]
      end

      def by_model_arm(draws) = draws.group_by { |draw| draw.values_at("model", "arm") }.sort_by { |key, _| key }

      def machine(decided, definition, home)
        [MACHINE, "", "```text", "verdict=#{decided.verdict}", "relaunch=#{decided.relaunch}",
         "definition_sha256=#{definition.sha256}", "stamp_sha256=#{Stamp.sha256(home)}", "```", ""]
      end

      private_class_method :report, :decide, :stamped, :unmoved!, :header, :stopped, :decision, :quality, :cost, :by_model_arm, :machine
    end
  end
end
