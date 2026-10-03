require "date"
require "digest"
require "yaml"
require_relative "../adaptation_rows"

module E2E
  module Evals
    # THE FROZEN CONFIG (rails/ai-evals' `bench.yml`): the tiers, the runs per task, the style rows,
    # the declared refusal fallbacks, the harness's patience. Its sha256 rides every record as
    # `bench_digest`; the scorecard refuses to mix digests in one table and the ledger groups by
    # digest, so a changed bench is a new column, never a blurred one. `subset(env)` NARROWS a run —
    # tasks, models, runs, styles, fallbacks — and refuses a stranger: the env never adds a model, a
    # style or a fallback the bench does not name.
    Bench = Data.define(:path, :document, :digest)

    # THE STYLE WORD THAT IS THE PACK ITSELF: on the bench's `tool_styles` beside the preset words;
    # `adaptations: auto` with `default_model` written, so the daemon boots under the SDK pack's row
    # for the model — the record's `adaptations` fact says which.
    PACK_STYLE = "pack".freeze

    class Bench
      DEFAULT_PATH = File.expand_path("../../evals/bench.yml", __dir__)
      DATED = /\A\d{4}-\d{2}-\d{2}-/
      # THE TIER WORDS, spelled once: `tiers` in bench.yml, in its order. The floor is read-only —
      # never tuned for — and its compose picture tasks are held to usable generation alone
      # (`Predicates.compose_bar`).
      STRONG = "strong".freeze
      FLOOR = "floor".freeze
      TIERS = [STRONG, FLOOR].freeze
      # THE CONTROL'S DOOR: `E2E_EVALS_FALLBACKS=off` runs the same bench with no declared fallback.
      FALLBACKS_ENV = "E2E_EVALS_FALLBACKS".freeze
      FALLBACKS_OFF = "off".freeze
      # THE LIVE LANES' WORD for a run's patience in money
      # (`LiveJourney::COST_STOP_ENV` reads it too): on this lane it may only
      # LOWER a task's stop (`Selection#cost_stop_usd`).
      COST_STOP_ENV = "E2E_LIVE_COST_STOP_USD".freeze

      def self.read(path = DEFAULT_PATH)
        bytes = File.read(path, encoding: Encoding::UTF_8)
        new(path: path, document: YAML.safe_load(bytes, permitted_classes: [], aliases: false),
          digest: Digest::SHA256.hexdigest(bytes))
      end

      def version = document.fetch("version")
      def canary = document.fetch("canary")
      # THE ROSTER: the ids a run that names no models runs.
      def tiers = document.fetch("tiers")
      def models = tiers.values.flatten
      # THE NAMED-ONLY MODELS, keyed by the same tier words: on a tier's BAR, never on the roster —
      # a run reads one only when E2E_EVALS_MODELS names it, so an unnamed run never pays for one.
      def named_only = document.fetch("named_only")
      # What a run MAY name: the roster, then the named-only ids.
      def nameable_models = models + named_only.values.flatten
      # A model's bar, over both lists: a named-only id reads its tier exactly as a roster id does.
      def tier_of(model) = tiers.merge(named_only) { |_tier, roster, named| roster + named }.find { |_tier, ids| ids.include?(model) }&.first
      # THE TIER FACT the lane stamps on every record: which bar a compose picture task reads off the
      # trace. A model neither list names stamps none, and reads the strong tier's bar.
      def tier_fact(model) = { "tier" => tier_of(model) }
      def runs_per_task = Integer(document.fetch("runs_per_task"))
      # THE DECLARED REFUSAL FALLBACKS: `fallbacks: {model => ref}`, the model a step the model
      # under test was REFUSED on re-runs once — the declaration rho writes on the answering
      # profile (`fallback_model`), never a model the kernel chooses. The bench's, so it is
      # digested with everything else and a run with one is a column apart from a run without;
      # a model the map names none for runs with none.
      def fallbacks = Hash(document["fallbacks"])
      def fallback_for(model) = fallbacks[model.to_s]
      def tool_styles = document.fetch("tool_styles")
      def approval = document.fetch("approval")
      def limits = document.fetch("limits")
      def deadline_seconds = Integer(limits.fetch("deadline_seconds"))
      def cost_stop_usd = Float(limits.fetch("cost_stop_usd"))
      # A task's own patience in money (`limits.cost_stop_usd_by_task`, the wall tasks since
      # 2026-09-11), else its FAMILY's (`limits.cost_stop_usd_by_family`, terminal-bench's $20 from
      # THEIR max), else the bench's: by task > by family > bench.
      def cost_stop_usd_by_task = Hash(limits["cost_stop_usd_by_task"]).transform_values { |usd| Float(usd) }
      def cost_stop_usd_by_family = Hash(limits["cost_stop_usd_by_family"]).transform_values { |usd| Float(usd) }

      def cost_stop_usd_for(task_name, family: nil)
        cost_stop_usd_by_task.fetch(task_name) { cost_stop_usd_by_family.fetch(family.to_s, cost_stop_usd) }
      end

      # THE HARNESS'S ONE ANSWER (version 10, the owner's ruling of
      # 2026-09-23): how many asks an unattended run answers before it
      # stops, and the exact sentence it answers with. The sentence is the
      # bench's, never a driver's literal and never tuned per model, so a
      # changed word is a changed digest and a new column.
      def unattended_answers_per_run = Integer(Hash(limits["unattended_answer"]).fetch("per_run", 0))
      def unattended_answer_text = Hash(limits["unattended_answer"]).fetch("text", "").to_s

      # THE CACHE HIT-RATE BAR (read after round 1): a family's floor on the rate over the spine's
      # rounds 2..n, read from `cache_floor_min_rounds` MEASURED rounds on (the rounds after the
      # first: a 2-round run has one) and never on a read-only id (`cache_floor_exempt_models`); nil
      # where no bar is read — a family the table does not name, an exempt model.
      def cache_floor_by_family = Hash(limits["cache_floor_by_family"]).transform_values { |rate| Float(rate) }
      def cache_floor_min_rounds = Integer(limits.fetch("cache_floor_min_rounds"))
      def cache_floor_exempt_models = Array(limits["cache_floor_exempt_models"]).map(&:to_s)

      def cache_floor_for(family, model:)
        return nil if cache_floor_exempt_models.include?(model.to_s)

        cache_floor_by_family[family.to_s]
      end

      # THE TERMINAL-BENCH BLOCK (policy, digest-bearing): the dataset and
      # its pinned commit, the 21 frozen names the loader filters the
      # checkout to, the default cell and the optional one
      # (`E2E::Evals::TerminalBench::Policy.of` reads it whole).
      def terminal_bench = Hash(document["terminal_bench"])
      def terminal_bench_names = Array(terminal_bench["tasks"]).map(&:to_s)
      def verifier = document.fetch("verifier")
      def runs_dir = File.expand_path(document.fetch("runs_dir"), File.dirname(path))
      def short_digest = digest[0, 12]

      # The narrowing: every list is a subset of the bench's own, the run count at most
      # `runs_per_task`; the label is dated unless it already is; the styles default to the FIRST
      # row alone (the plain names) — the compose-name row is opted in per invocation, not paid for
      # by every task of every family. The models default to the roster alone: a `named_only` id is
      # nameable, never a default, so it enters a run only through E2E_EVALS_MODELS. The declared
      # fallbacks are the bench's whole map, or none under `E2E_EVALS_FALLBACKS=off`. The one door of
      # the RUN step: `E2E_EVALS_CANDIDATE=<row>/<id>` reads a harness candidate under the `pack`
      # word alone, on a strong-tier model alone (the tier rule's bench half: a floor model is
      # refused).
      def subset(env = ENV, today: Date.today)
        models = pick(env["E2E_EVALS_MODELS"], nameable_models, "model", default: self.models)
        styles = pick(env["E2E_EVALS_STYLES"], tool_styles, "style", default: tool_styles.first(1))
        runs = Integer(env.fetch("E2E_EVALS_RUNS", runs_per_task))
        raise ArgumentError, "E2E_EVALS_RUNS must be 1..#{runs_per_task}, got #{runs}" unless (1..runs_per_task).cover?(runs)

        label = env["E2E_EVALS_LABEL"].to_s.empty? ? models.map { |m| Bench.slug(m) }.join("+") : env["E2E_EVALS_LABEL"]
        dir = env["E2E_EVALS_RUNS_DIR"].to_s.empty? ? runs_dir : File.expand_path(env["E2E_EVALS_RUNS_DIR"])
        Selection.new(tasks_glob: env.fetch("E2E_EVALS_TASKS", "*"), models: models, styles: styles, runs: runs,
          label: label.match?(DATED) ? label : "#{today.iso8601}-#{label}", runs_dir: dir,
          models_named: !env["E2E_EVALS_MODELS"].to_s.strip.empty?,
          candidate: candidate(env["E2E_EVALS_CANDIDATE"], models: models, styles: styles),
          cost_stop_ceiling: cost_stop_ceiling(env[COST_STOP_ENV]), fallbacks: selected_fallbacks(env[FALLBACKS_ENV]))
      end

      def self.slug(model) = model.to_s.tr("/", "_")

      private

        # The bench's map, refused whole when it names a model the bench does not; the env may
        # only switch it off.
        def selected_fallbacks(raw)
          stranger = fallbacks.keys.find { |model| !nameable_models.include?(model) }
          raise ArgumentError, "fallbacks names #{stranger.inspect}, not a model the bench names: #{nameable_models.join(", ")}" if stranger

          case raw.to_s.strip
          when "" then fallbacks
          when FALLBACKS_OFF then {}
          else raise ArgumentError, %(#{FALLBACKS_ENV} takes "#{FALLBACKS_OFF}" alone (the control run with no fallback), got #{raw.to_s.strip.inspect})
          end
        end

        def cost_stop_ceiling(raw)
          return nil if raw.to_s.strip.empty?

          usd = Float(raw)
          raise ArgumentError, "#{COST_STOP_ENV} must be above 0, got #{raw}" unless usd.positive?

          usd
        end

        # A candidate is the gem row PLUS one text, so it is read under the
        # `pack` word alone and only on models the candidate's row covers —
        # every one on the strong tier (floors are read-only, never tuned for).
        def candidate(raw, models:, styles:)
          return nil if raw.to_s.strip.empty?

          candidate = E2E::AdaptationRows.find(raw)
          raise ArgumentError, "E2E_EVALS_CANDIDATE=#{candidate.key} is read under E2E_EVALS_STYLES=#{PACK_STYLE} alone, got #{styles.join(",")}" unless
            styles == [PACK_STYLE]
          models.each do |model|
            row = E2E::AdaptationRows.pack.for(model)
            raise ArgumentError, "E2E_EVALS_CANDIDATE=#{candidate.key}: #{model} resolves to row #{row.id}, not #{candidate.row_id}" unless
              row.id == candidate.row_id
            raise ArgumentError, "E2E_EVALS_CANDIDATE=#{candidate.key}: #{model} is on the #{FLOOR} tier (read-only, never tuned for)" if
              tier_of(model) == FLOOR
          end
          candidate
        end

        def pick(raw, allowed, what, default: allowed)
          return default if raw.to_s.strip.empty?

          chosen = raw.split(",").map(&:strip).reject(&:empty?)
          stranger = chosen.find { |id| !allowed.include?(id) }
          raise ArgumentError, "#{stranger.inspect} is not a #{what} the bench names: #{allowed.join(", ")}" if stranger

          chosen
        end
    end

    # `models_named`: the env NAMED the models (never the bench's whole
    # list) — the one door a task's OPTIONAL model opens through (`Plan`).
    # `candidate`: an `AdaptationRows::Candidate` or nil — it rides every
    # Run of the selection. `cost_stop_ceiling`: the env's lower patience in
    # money for this invocation, or nil. `fallbacks`: the declared refusal
    # fallbacks this invocation runs under, `{model => ref}` — the bench's
    # map, or none for the control; each rides its model's Runs.
    Selection = Data.define(:tasks_glob, :models, :styles, :runs, :label, :runs_dir, :models_named, :candidate,
      :cost_stop_ceiling, :fallbacks) do
      def initialize(tasks_glob:, models:, styles:, runs:, label:, runs_dir:, models_named: false, candidate: nil,
        cost_stop_ceiling: nil, fallbacks: {})
        super
      end

      def fallback_for(model) = fallbacks[model]

      def run_dir = File.join(runs_dir, label)

      # A run's stop: the task's (`Bench#cost_stop_usd_for`), lowered — never
      # raised — by the invocation's ceiling.
      def cost_stop_usd(task_stop) = [task_stop, cost_stop_ceiling].compact.min

      # The plan line's tail: what a cell runs under beyond its model and style — the RUN step's
      # door, and each selected model's declared fallback.
      def doors
        [("candidate #{candidate.key}" if candidate),
         *models.filter_map { |model| "fallback #{model} → #{fallback_for(model)}" if fallback_for(model) }].compact
      end
    end
  end
end
