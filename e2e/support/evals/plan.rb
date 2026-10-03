require "yaml"
require_relative "bench"
require_relative "../adaptation_rows"

module E2E
  module Evals
    # WHAT ONE INVOCATION RUNS: every selected task × the selected models on its tiers (narrowed by
    # the task's own `models` when it names any) × the selected styles × 1..runs, grouped by the
    # DAEMON CONFIGURATION each needs — compaction mode × style × a second runner-mode home — the
    # gallery's two-daemons rule: one daemon per configuration, every run of the group inside it,
    # each in its own project dir. The delegate's summarizer names a model, so a delegate
    # configuration is per model too; so is the `pack` style (the SDK pack's row for the model is
    # the daemon's BOOT row, read off `default_model`), and the RUN step's one door — a candidate —
    # rides the selection into every Run and so into its configuration, as each model's declared
    # refusal fallback does (one daemon's settings declare one). A CONTAINER FAMILY's task
    # names its `image`: the configuration carries it, so one group is one derived image, paired
    # once as the group's runner home and run as a FRESH container per run (the lane's `restart!`).
    # Pure: the Rakefile sizes the world's patience from the plan without booting anything.
    Run = Data.define(:task, :model, :style, :index, :candidate, :fallback_model) do
      def initialize(task:, model:, style:, index:, candidate: nil, fallback_model: nil)
        super
      end

      def key = [task.name, model, style, index]

      # The run's own name — its project directory under the group's home and its artifact's
      # basename alike: every field of the key, so no two runs of a plan share a directory.
      def stem = "#{task.name}.#{Bench.slug(model)}.#{style}.#{index}"
    end

    # A preset word is a harness-written LOCAL row under the home's
    # `adaptations/`, pinned by name: exactly the set every 12a/12b
    # record ran (`workflow` ALONE, never `[nexus, workflow]`).
    BENCH_ROW_PREFIX = AdaptationRows::BENCH_ROW_PREFIX

    Configuration = Data.define(:compaction, :style, :runner_home, :summary_model, :image, :model, :candidate,
      :fallback_model) do
      def self.for(run)
        new(compaction: run.task.compaction, style: run.style, runner_home: run.task.runner_home?,
          summary_model: (run.model if run.task.compaction == "delegate"), image: run.task.image,
          model: (run.model if run.style == PACK_STYLE), candidate: run.candidate, fallback_model: run.fallback_model)
      end

      # A Minitest method name and a tmpdir prefix: the image's `/` and `:`
      # never reach either.
      def slug
        [compaction, style.tr("+", "_"), (runner_home ? "runner" : nil), summary_model&.tr("/", "_"),
         model&.tr("/", "_"), candidate&.slug, (fallback_model && "fallback_#{fallback_model.tr("/", "_")}"),
         image&.gsub(/[^A-Za-z0-9._-]+/, "_")].compact.join("__")
      end

      def container? = !image.nil?

      def pack? = style == PACK_STYLE

      # The local row's id for a preset word: `bench-workflow`, `bench-nexus-claude`.
      def row_id = AdaptationRows.bench_row_id(style)

      # The daemon home's `settings.json` before boot: the compaction mode (the delegate with its
      # model, as live_long_session writes it), the adaptations knob — the local row by name, or
      # `auto` beside `default_model` under `pack` — and `compose: on` — the switch narrows by the
      # flat name and the alias row must never be the thing it withholds — and `rho/dev`, the
      # development gem the drivers type through (`rho watch`, `rho say`, `rho answer`, `rho
      # request`). No `tool_style` is written anywhere: the three per-model settings tables left
      # with the pack. A declared refusal fallback is rho's `fallback_model` setting, which rho
      # declares on the answering profile; a configuration with none writes no key.
      def settings
        base = { "compaction" => { "mode" => compaction, "model" => summary_model }.compact, "compose" => "on",
                 "extensions" => ["rho/dev"], "fallback_model" => fallback_model }.compact
        pack? ? base.merge("adaptations" => "auto", "default_model" => model) : base.merge("adaptations" => row_id)
      end

      # THE `fallback_model` FACT on every record: the fallback the run declared, nil when it
      # declared none — a record always says what it ran under.
      def fallback_fact = { "fallback_model" => fallback_model }

      # THE LOCAL ROWS the lane writes under the home's `adaptations/`
      # before boot, `{id => yaml}`: one for a preset word — the style's
      # words, `compose: on`, `models: []`, no text; under `pack` none,
      # unless a candidate is named — then the gem row PLUS the candidate,
      # of the gem row's own id, which `auto` resolves in the gem row's place.
      def local_rows
        return { row_id => YAML.dump(AdaptationRows.word_row(row_id, style.split("+"))) } unless pack?
        return {} if candidate.nil?

        { candidate.row_id => YAML.dump(AdaptationRows.apply(candidate)) }
      end

      # THE `adaptations` FACT on every record: `{row, source, tool_style
      # [, candidate]}` for the row the daemon boots under — the gem row for
      # the model under `pack`, else the local row the lane wrote (a preset
      # word's, or the candidate's when one is named). The declared set is
      # reconstructed from the words, never from the style word alone
      # (`pack` names no words).
      def adaptations_fact
        fact = if pack? && candidate.nil?
          row = AdaptationRows.pack.for(model)
          { "row" => row.id, "source" => row.source, "tool_style" => row.tool_style.to_a }
        else
          id, yaml = local_rows.first
          { "row" => id, "source" => "local", "tool_style" => YAML.safe_load(yaml).fetch("tool_style") }
        end
        candidate ? fact.merge("candidate" => candidate.key) : fact
      end
    end

    module Plan
      BOOT_AND_TEARDOWN_SLACK_SECONDS = 900
      # A container family's derived image builds once per base — an
      # emulated amd64 installer run on this Mac took minutes for the
      # writebook base; cached by tag after — inside the group's own time.
      IMAGE_BUILD_SLACK_SECONDS = 1800

      module_function

      # A model a task names OPTIONAL (terminal-bench's kimi-k3 comparison
      # cell) runs only when the selection NAMED its models
      # (`E2E_EVALS_MODELS`), never from the bench's whole list; a task's
      # `runs_for` caps the selection's n to its cell's.
      def build(corpus, bench, selection)
        corpus.select(selection.tasks_glob).flat_map do |task|
          selection.models.select { |model| task.on_tier?(bench.tier_of(model)) && admits?(task, model, selection) }.flat_map do |model|
            selection.styles.flat_map do |style|
              (1..task.runs_for(model, selection.runs)).map do |index|
                Run.new(task: task, model: model, style: style, index: index, candidate: selection.candidate,
                  fallback_model: selection.fallback_for(model))
              end
            end
          end
        end
      end

      def admits?(task, model, selection) = task.on_model?(model) || (selection.models_named && task.optional_model?(model))

      def groups(runs) = runs.group_by { |run| Configuration.for(run) }

      # EVERY MODEL A GROUP'S WORLD MUST SERVE — the lane enables each one's provider: the models
      # under test and the refusal fallback each declares, since the kernel refuses a
      # `fallback_model` declaration its account cannot run (`provider_disabled`).
      def served_models(runs) = runs.flat_map { |run| [run.model, run.fallback_model] }.compact.uniq

      # TWICE each run's deadline: a driver awaits the loop and then its
      # tasks (or the receipts, or a woken turn) under the same deadline,
      # so a run that goes red on the harness's patience may hold the
      # world for two of them before its record is written — the budget
      # must outlive the reds, never only the greens.
      # A container family adds one build's slack per distinct image.
      def journey_seconds(runs)
        images = runs.filter_map { |run| run.task.image }.uniq
        runs.sum { |run| 2 * run.task.deadline_seconds } + BOOT_AND_TEARDOWN_SLACK_SECONDS + images.size * IMAGE_BUILD_SLACK_SECONDS
      end
    end
  end
end
