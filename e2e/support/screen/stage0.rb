require "digest"
require "etc"
require "open3"
require "time"
require_relative "analysis"
require_relative "bytes"
require_relative "corpus"
require_relative "counterfactual"
require_relative "door_reader"
require_relative "job"
require_relative "rates"
require_relative "readout"
require_relative "replay_gate"
require_relative "smoke"
require_relative "stamp"
require_relative "stems"
require_relative "stop"
require_relative "watch"

module E2E
  module Screen
    # STAGE 0: every free gate a screen passes before a paid draw, in one registered order, then the
    # stamp. Preconditions (the definition and the design section it registers, the corpus extracts'
    # shas, a fresh home, the one relaunch) → the trees (clean, the without tree AT the base — the
    # with tree's merge base with the definition's `base_ref` — that ref not past it, no transport
    # difference, the arm's diff inside the allowlist) → nothing else heavy on the machine → the
    # bytes each arm sends → the held-out stems → the rates, both trees agreeing → the replay over the
    # tracked corpus in each tree → the builder counterfactual in each tree → the door reader against
    # its register → the carried inputs unchanged → the analysis's dry run and its stops → the smoke
    # → THE STAMP. A refusal names its step; nothing after it runs.
    #
    # A fake rehearsal reports the machine-state gates rather than refusing on them (a rehearsal runs
    # on a working tree), skips the gates that need a kernel boot or a pair of records, and smokes
    # through the fake transport; a dry run enforces everything free and stops at a rehearsal stamp
    # with no smoke and no job; a real launch enforces all of it.
    class Stage0
      MODES = %w[fake dry real].freeze
      # A run of these reports its refusal and goes on.
      REPORTED = { "fake" => %i[trees load stems], "dry" => %i[load], "real" => [] }.freeze
      SKIPPED = { "fake" => %i[replay counterfactual door_reader c_inputs dry], "dry" => %i[smoke], "real" => [] }.freeze
      STEPS = %i[preconditions trees load bytes stems rates replay counterfactual door_reader c_inputs dry smoke].freeze
      # THE MACHINE'S OWN WORK LEAVES ROOM WHILE ITS ONE-MINUTE LOAD IS UNDER ITS CORE COUNT: a screen
      # waits on providers, and what a model writes does not depend on this machine's CPU; the wall
      # and stall stops bound a slow harness. (A fixed 8 refused a 16-core machine at load 13.)
      LOAD_CEILING = Float(Etc.nprocessors)
      BUSY = ["rake live_", "rake e2e", "e2e_group", "e2e_serial", "compose_matrix_probe_test", "task_matrix_probe_test"].freeze

      attr_reader :pairs

      # `smoke_runner` spawns the smoke's jobs and waits for them; `pricer` answers a record's
      # dollars once the rates are written; `analysis` answers `dry(definition, pair_dir)`;
      # `readout_root` is the tree the screen's readout — its ledger — lands in (the with tree's).
      def initialize(definition:, trees:, home:, mode:, smoke_runner:, pricer:, analysis: Analysis, supersedes: nil, readout_root: nil,
                     command: CAPTURE, bytes: Bytes, rates: Rates, replay: ReplayGate, counterfactual: Counterfactual,
                     door_reader: DoorReader, busy: nil, clock: -> { Time.now.utc })
        raise ArgumentError, "mode is #{MODES.join(", ")}, not #{mode.inspect}" unless MODES.include?(mode)

        @definition = definition
        @trees = trees
        @home = home
        @mode = mode
        @smoke_runner = smoke_runner
        @pricer = pricer
        @analysis = analysis
        @supersedes = supersedes
        @readout_root = readout_root || trees.fetch("with")
        @command = command
        @bytes = bytes
        @rates = rates
        @replay = replay
        @counterfactual = counterfactual
        @door_reader = door_reader
        @busy = busy || method(:machine_busy)
        @clock = clock
        @pairs = []
      end

      # Every step in order, then the stamp; the stamp's path.
      def call
        STEPS.each { |step| run(step) }
        Stamp.write(@home, @pairs + closing_pairs)
      end

      private

        def run(step)
          if SKIPPED.fetch(@mode).include?(step)
            @pairs << ["stage0.#{step}", "skipped (#{@mode})"]
          else
            @pairs.concat(send(step))
          end
        rescue Refused => error
          raise Refused, "stage 0 #{step}: #{error.message}" unless REPORTED.fetch(@mode).include?(step)

          @pairs << ["stage0.#{step}", "REPORTED, not enforced (#{@mode}): #{error.message}"]
        end

        def preconditions
          raise Refused, "#{Stamp.path(@home)} exists: a home is stamped once" if File.exist?(Stamp.path(@home))

          section = @definition.design_section(@trees.fetch("with"))
          [["mode", @mode], ["screen", @definition.name], ["definition_sha256", @definition.sha256],
           ["design", "#{@definition.design.fetch("path")} #{@definition.design.fetch("section")}"],
           ["design_section_sha256", Digest::SHA256.hexdigest(section)],
           *Corpus::FILES.keys.map { |id| ["corpus.#{id}", Corpus.sha256(id)] }, *relaunch_pairs]
        end

        # THE ONE RELAUNCH, read from the screen's ledger (`Readout`): a screen whose readout holds a
        # launch is launched again only as that launch's relaunch; one whose readout holds none (a
        # launch whose last act read nothing out) is relaunched only over a home a registered stop
        # ended. Never over a relaunch, and never over another screen's launch.
        def relaunch_pairs
          latest = Readout.latest(Readout.dir(@readout_root, @definition))
          if @supersedes
            reason = superseded(latest)
            [["supersedes", "#{@supersedes} (#{reason})"], ["supersedes_stamp_sha256", Stamp.sha256(@supersedes)],
             ["candidate_cap_usd", @definition.relaunch.fetch("candidate_cap_usd")]]
          elsif latest
            raise Refused, "#{Readout.dir(@readout_root, @definition)} reads out the launch of #{latest.stamp["launched_at"]}: " \
                           "a screen is launched once, and once more only as the relaunch that launch owes (--supersedes)"
          else
            []
          end
        end

        # Why the superseded launch owes the relaunch.
        def superseded(latest)
          raise Refused, "#{@supersedes} holds no stamp: it launched nothing to relaunch" unless File.file?(Stamp.path(@supersedes))

          old = Stamp.read(@supersedes)
          raise Refused, "#{@supersedes} launched #{old["screen"].inspect}, not #{@definition.name}" unless old["screen"] == @definition.name
          raise Refused, "#{@supersedes} was itself the relaunch: the one relaunch is spent" if old.key?("supersedes")

          latest ? owed_by_readout(latest) : owed_by_stop
        end

        # The readout must hold the superseded launch itself, and its analysis must owe the relaunch:
        # a registered stop, a kernel finding, lost draws over the floor.
        def owed_by_readout(latest)
          unless latest.stamp_sha256 == Stamp.sha256(@supersedes)
            spent = latest.stamp.key?("supersedes") ? "the one relaunch is spent" : "only the launch read out last is relaunched"
            raise Refused, "the readout holds the launch of #{latest.stamp["launched_at"]}, not #{@supersedes}'s: #{spent}"
          end
          verdict, relaunch = latest.machine.values_at("verdict", "relaunch")
          raise Refused, "#{@supersedes} read out #{verdict}: no relaunch is owed" if relaunch == "none"

          "#{verdict} #{relaunch}"
        end

        def owed_by_stop
          reason = Stop.reason(@supersedes)
          raise Refused, "#{@supersedes} has no registered stop: a screen is relaunched only after one" unless reason
          raise Refused, "#{@supersedes} stopped by hand naming no fault (#{reason}): no relaunch is owed" unless WatchRules.relaunch_owed?(reason)

          reason
        end

        # The trees' heads and states are stamped before any check refuses — reading the base ref
        # included, which a shallow clone may lack — so a rehearsal that only reports these checks
        # still hands the watch and the analysis the states they must see unchanged.
        def trees
          heads = @trees.transform_values { |root| git(root, "rev-parse", "HEAD").strip }
          @pairs.concat([*heads.map { |tag, head| ["head.#{tag}", head] },
                         *@trees.flat_map { |tag, root| [["tree.#{tag}.root", root], ["tree.#{tag}.state", Watch.tree_state(root)]] }])
          ref = @definition.base_ref
          base = base_of_with
          ref_head = git(@trees.fetch("with"), "rev-parse", ref).strip
          @pairs.concat([["base_ref", ref], ["base", base], ["base_ref_head", ref_head]])
          @trees.each { |tag, root| refuse_dirty(tag, root) }
          raise Refused, "the without tree is at #{heads.fetch("without")[0, 8]}, not the base #{base[0, 8]}" unless heads.fetch("without") == base
          raise Refused, "#{ref} is at #{ref_head[0, 8]}, past the base #{base[0, 8]}: merge #{ref} into the with branch first" unless ref_head == base

          changed = git(@trees.fetch("with"), "diff", "--name-only", base, heads.fetch("with")).lines(chomp: true)
          transport = changed.select { |path| matches?(@definition.transport, path) }
          raise Refused, "the with branch changes the shared transport: #{transport.join(", ")}" if transport.any?

          outside = changed.reject { |path| matches?(@definition.allowlist, path) }
          raise Refused, "the with branch changes paths outside the allowlist: #{outside.join(", ")}" if outside.any?

          [["transport_diff", "none"], ["allowlist_diff", changed.empty? ? "none" : changed.join(" ")]]
        end

        # A tree is clean over everything a screen watches (`WATCHED`) — the readouts aside, so a
        # same-day relaunch is not refused over the untracked one it supersedes.
        def refuse_dirty(tag, root)
          dirty = git(root, "status", "--porcelain", "--untracked-files=all", "--", *WATCHED).lines(chomp: true)
          raise Refused, "the #{tag} tree #{root} has uncommitted changes: #{dirty.first(3).join("; ")}" if dirty.any?
        end

        def load
          busy, load = @busy.call
          raise Refused, "something heavy runs beside the screen: #{busy.first(3).join("; ")}" if busy.any?
          raise Refused, "the one-minute load is #{load}, not under #{LOAD_CEILING}" unless load < LOAD_CEILING

          [["load_1min", load.to_s], ["load_ceiling", LOAD_CEILING.to_s]]
        end

        def bytes = @bytes.call(definition: @definition, trees: @trees, home: @home, command: @command)

        # THE HELD-OUT CHECK: each primary stimulus against the stems the arm's diff adds; a listed
        # stem stops the launch; the controls' intersections print.
        def stems
          spec = @definition.stage0["stems"]
          return [["stems", "not registered"]] unless spec

          added = git(@trees.fetch("with"), "diff", "-U0", base_of_with, "HEAD", "--", *spec.fetch("paths"))
            .lines.select { |line| line.start_with?("+") && !line.start_with?("+++") }.map { |line| line.delete_prefix("+") }
          arm = @definition.arms.find { |candidate| candidate.tree == "with" }
          %w[primary control].flat_map do |role|
            spec.fetch(role, {}).flat_map do |instrument, ids|
              ids.map { |id| stem_pair(role, instrument, id, added, arm, spec.fetch("list")) }
            end
          end
        end

        def stem_pair(role, instrument, id, added, arm, list)
          shared = Stems.intersection(Bytes.objective(@home, arm.id, instrument, id), added, list: list)
          listed = Stems.listed(shared, list: list)
          raise Refused, "the primary #{instrument} #{id} shares the listed stems #{listed.to_a.sort.join(", ")}" if role == "primary" && listed.any?

          ["stems.#{role}.#{instrument}.#{id}", shared.to_a.sort.join(",").then { |text| text.empty? ? "none" : text }]
        end

        def rates = @rates.call(definition: @definition, trees: @trees, home: @home)

        def replay
          return [["replay", "not registered"]] unless @definition.stage0["replay"]

          @replay.call(definition: @definition, trees: @trees)
        end

        # THE BUILDER COUNTERFACTUAL: the same stored scripts build in both trees, and the door reader
        # answers every one (`Counterfactual`).
        def counterfactual
          return [["counterfactual", "not registered"]] unless @definition.stage0["counterfactual"]

          @counterfactual.call(definition: @definition, trees: @trees, command: @command)
        end

        # THE DOOR READER over the tracked door records, against its register (`DoorReader`).
        def door_reader
          return [["door_reader", "not registered"]] unless @definition.stage0["door_reader"]

          @door_reader.call(definition: @definition, trees: @trees, command: @command)
        end

        # THE CARRIED INPUTS: a reading carried from an earlier stamp stands only while the files it
        # read are unchanged since.
        def c_inputs
          spec = @definition.stage0["c_inputs"]
          return [["c_inputs", "not registered"]] unless spec

          moved = git(@trees.fetch("with"), "diff", "--name-only", "#{spec.fetch("since")}..HEAD", "--", *spec.fetch("paths")).lines(chomp: true)
          raise Refused, "the carried inputs changed since #{spec.fetch("since")[0, 8]}: #{moved.join(", ")}" if moved.any?

          [["c_inputs", "unchanged since #{spec.fetch("since")}"], *spec.fetch("carried", []).each_with_index.map { |line, i| ["c_inputs.carried.#{i + 1}", line] }]
        end

        # THE ANALYSIS'S DRY RUN over the registered pair: its figures at this screen's n ride the
        # stamp, and a stop it names stops the launch.
        def dry
          spec = @definition.stage0["dry"]
          return [["dry", "not registered"]] unless spec

          figures = @analysis.dry(@definition, File.expand_path(spec.fetch("pair"), @definition.dir))
          raise Refused, "the dry run stops: #{figures.stops.join("; ")}" if figures.stop?

          figures.stamp_lines.map { |line| line.split("=", 2) }
        end

        def smoke
          jobs = Smoke.jobs(@definition)
          @smoke_runner.call(jobs)
          result = Smoke.read(@home, jobs, pricer: @pricer)
          raise Refused, "the smoke failed: #{result.lines.grep(/FAIL/).join("; ")}" unless result.ok

          [*result.lines.map { |line| line.split("=", 2) }, ["smoke_spend_usd", format("%.6f", result.spend_usd)],
           ["smoke_ids", result.ids.join(",")]]
        end

        def closing_pairs
          jobs = @definition.jobs
          [*@definition.caps.map { |prefix, cap| ["cap.#{prefix}", cap] },
           ["budget.planning_usd", @definition.budget.fetch("planning_usd")], ["budget.upper_usd", @definition.budget.fetch("upper_usd")],
           *@definition.arms.map { |arm| ["cache_key.#{arm.id}", "#{@definition.name}/#{arm.id}/<lane>"] },
           *watch_params.lines.map { |line| line.split("=", 2) },
           *candidate_pairs,
           ["jobs", jobs.size], *jobs.map { |job| ["job.#{job.index}", job.stamp_line] },
           ["launched_at", @clock.call.iso8601]]
        end

        # A relaunch has its own spend stop; a fake run's clocks are the definition's fake ones.
        def watch_params
          params = @definition.watch_params(fake: @mode == "fake")
          @supersedes ? params.with(spend_stop_usd: Float(@definition.relaunch.fetch("spend_stop_usd"))) : params
        end

        # The candidate queue, registered by sha before the first screen of a target.
        def candidate_pairs
          @definition.stage0.fetch("candidates", []).map { |ref| ["candidate.#{ref}", git(@trees.fetch("with"), "rev-parse", ref).strip] }
        end

        def base_of_with = git(@trees.fetch("with"), "merge-base", "HEAD", @definition.base_ref).strip

        # A git read is data (a sha, a listing, a diff): stdout alone, stderr only in the refusal. Git
        # writes a diff's lines as the files' own UTF-8 whatever the locale, so the output is read as
        # UTF-8 here, once, before the stems step scans an added line.
        def git(root, *args)
          out, ok, err = @command.call(["git", "--no-optional-locks", "-C", root, *args], chdir: root)
          raise Refused, "git #{args.first} failed in #{root}: #{err.to_s.lines.first.to_s.strip}" unless ok

          String.new(out, encoding: Encoding::UTF_8)
        end

        def matches?(globs, path) = globs.any? { |glob| File.fnmatch?(glob, path, File::FNM_EXTGLOB) }

        # What else runs on the machine: a paid lane, an e2e world, another probe; and the load.
        def machine_busy
          busy = BUSY.flat_map do |pattern|
            out, status = Open3.capture2("pgrep", "-fl", pattern)
            status.success? ? out.lines(chomp: true) : []
          end
          uptime, = Open3.capture2("uptime")
          [busy, Float(uptime[/load averages?:\s*([\d.]+)/, 1])]
        end
    end
  end
end
