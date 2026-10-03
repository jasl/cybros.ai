require "digest"
require "yaml"
require_relative "../provider_lanes"
require_relative "../fake_bench_adapter"
require_relative "corpus"
require_relative "job"
require_relative "watch_rules"

module E2E
  module Screen
    # AN ARM: which tree it runs in (`with` or `without` — the launch's two tree arguments), the
    # compose bench's row it reads, and whether it is the base the other is read against.
    Arm = Data.define(:id, :tree, :row, :base)
    # A CELL: models × objectives at `n` draws each, on one instrument, cut into `split` jobs by
    # sample halves (so a slow lane runs as several processes, and the halves read against each
    # other as an A/A).
    Cell = Data.define(:instrument, :models, :objectives, :n, :split)

    # A SCREEN'S DEFINITION: one tracked `<dir>/screen.yml` — the design section it registers, the
    # arms, the allowlist and transport lists the trees are checked against, the cells, the lane
    # caps, the smoke, the watch's parameters (and a fake run's shorter clocks), the budget, the
    # relaunch terms and the Stage 0 gates it names. Loaded and checked once; the job table follows
    # by rule. Trees are never written here: `tree_root` maps an arm to the launch's arguments.
    #
    # Its `sha256` is the whole directory's — `screen.yml` and every file beside it, the `clauses.rb`
    # the analysis decides by among them — since the directory may sit outside both stamped trees:
    # a rule edited after the stamp is another definition, and the analysis refuses it.
    Definition = Data.define(:dir, :name, :design, :arms, :base_ref, :allowlist, :transport, :style, :max_output_tokens, :floors,
      :cells, :caps, :smoke, :watch, :fake, :budget, :relaunch, :stage0, :sha256) do
      def self.load(dir)
        path = File.join(dir, "screen.yml")
        yaml = YAML.safe_load(File.read(path, encoding: Encoding::UTF_8))
        new(dir: File.expand_path(dir), name: yaml.fetch("name"), design: yaml.fetch("design").slice("path", "section"),
          arms: yaml.fetch("arms").map { |arm| Arm.new(id: arm.fetch("id"), tree: arm.fetch("tree"), row: arm["row"], base: arm["base"] == true) },
          base_ref: yaml.fetch("base_ref", "main").to_s,
          allowlist: yaml.fetch("allowlist"), transport: yaml.fetch("transport"), style: yaml.fetch("style"),
          max_output_tokens: Integer(yaml.fetch("max_output_tokens")), floors: yaml.fetch("floors", []),
          cells: yaml.fetch("cells").map { |cell| cell_of(cell) }, caps: yaml.fetch("caps").transform_values { |cap| Integer(cap) },
          smoke: yaml.fetch("smoke"), watch: yaml.fetch("watch"), fake: yaml.fetch("fake", {}), budget: yaml.fetch("budget"),
          relaunch: yaml.fetch("relaunch"), stage0: yaml.fetch("stage0", {}), sha256: sha256_of(dir))
      end

      # Each file's path under the directory and its bytes' hash, in path order, hashed once more; a
      # dotfile (a desktop's `.DS_Store`) is no part of a definition. Public: a launch stamps any
      # directory it registers (including task fixture directories) by the same rule.
      def self.sha256_of(dir)
        files = Dir.glob("**/*", base: dir).select { |name| File.file?(File.join(dir, name)) }.sort
        Digest::SHA256.hexdigest(files.map { |name| "#{name}\0#{Digest::SHA256.file(File.join(dir, name)).hexdigest}\n" }.join)
      end

      def self.cell_of(cell)
        Cell.new(instrument: cell.fetch("instrument"), models: cell.fetch("models"), objectives: cell.fetch("objectives"),
          n: Integer(cell.fetch("n")), split: Integer(cell.fetch("split", 1)))
      end
      private_class_method :cell_of

      def initialize(**fields)
        super
        validate_fields
      end

      def base_arm = arms.find(&:base)
      def arm(id) = arms.find { |arm| arm.id == id } || raise(ArgumentError, "the definition has no arm #{id.inspect}")
      def instruments = cells.map(&:instrument).uniq
      def models = cells.flat_map(&:models).uniq
      # Every model the launch draws and prices: the cells', then the smoke's.
      def drawn_models = (models + smoke.fetch("models")).uniq

      # The tree an arm runs in, from the launch's `{"with" => root, "without" => root}`.
      def tree_root(arm_id, trees) = trees.fetch(arm(arm_id).tree)

      # THE POST-STORM LAYOUT a relaunch after a storm runs under: the registered lower caps and,
      # when named, every split cell merged back into one job per (arm, model).
      def after_storm
        spec = relaunch.fetch("post_storm")
        merged = spec.fetch("merge_splits", false) ? cells.map { |cell| cell.with(split: 1) } : cells
        with(caps: caps.merge(spec.fetch("caps").transform_values { |cap| Integer(cap) }), cells: merged)
      end

      def stagger_seconds = Float(relaunch.dig("post_storm", "stagger_seconds") || 0)

      # The watch's parameters; a fake run's shorter clocks replace the named ones.
      def watch_params(fake: false) = WatchRules::Params.from(fake ? watch.merge(self.fake) : watch)

      # THE JOB TABLE: per arm, every cell's model, a split cell once per part with its own first
      # sample; floors first, then the definition's order.
      def jobs
        listed = arms.flat_map do |arm|
          cells.each_with_index.flat_map do |cell, number|
            cell.models.flat_map do |model|
              size = cell.n / cell.split
              (0...cell.split).map { |part| [arm, cell, number, model, part, size] }
            end
          end
        end
        ordered = listed.each_with_index.sort_by { |(_, _, _, model), position| [floors.include?(model) ? 0 : 1, position] }.map(&:first)
        ordered.each_with_index.map { |(arm, cell, number, model, part, size), position| job(position + 1, arm, cell, number, model, part, size) }
      end

      # The registered section of the design, heading line to the next heading of its level; its
      # hash rides the stamp, so a rule edited after the stamp is visible.
      def design_section(repo_root)
        lines = File.read(File.join(repo_root, design.fetch("path")), encoding: Encoding::UTF_8).lines
        start = lines.index { |line| line.match?(/\A#+ /) && line.sub(/\A#+ /, "").strip == design.fetch("section") }
        raise ArgumentError, "#{design.fetch("path")} has no section \"#{design.fetch("section")}\"" unless start

        level = lines[start][/\A#+/].size
        finish = lines[(start + 1)..].index { |line| line[/\A(#+) /, 1].to_s.size.between?(1, level) }
        lines[start, finish ? finish + 1 : lines.size - start].join
      end

      private

        # Each job its own directory: the model's, then the cell's number when the model is in more
        # than one cell of the instrument, then the part of a split cell.
        def job(index, arm, cell, number, model, part, size)
          name = [model.tr("/", "_"), ("cell#{number + 1}" if cells_of(cell.instrument, model) > 1),
                  (part + 1 if cell.split > 1)].compact.join(".")
          Job.new(index: index, arm: arm.id, instrument: cell.instrument, model: model, objectives: cell.objectives, n: size,
            sample_first: part * size + 1, dir: [arm.id, cell.instrument, name].join("/"), lane: ProviderLanes.provider_of(model),
            row: (arm.row if cell.instrument == "compose"), style: style)
        end

        def cells_of(instrument, model) = cells.count { |cell| cell.instrument == instrument && cell.models.include?(model) }

        def validate_fields
          raise ArgumentError, "#{name}: one arm is the base, not #{arms.count(&:base)}" unless arms.count(&:base) == 1
          raise ArgumentError, "#{name}: arm ids repeat" unless arms.map(&:id).uniq.size == arms.size

          arms.each do |arm|
            raise ArgumentError, "#{name}: arm #{arm.id} runs in #{arm.tree.inspect}, not with or without" unless %w[with without].include?(arm.tree)
          end
          raise ArgumentError, "#{name}: base_ref names no ref" if base_ref.strip.empty?

          cells.each { |cell| validate_cell(cell) }
          validate_draws
          validate_stage0
          smoke.fetch("models").each { |model| model.start_with?("fake/") ? FakeBenchAdapter.route(model) : ProviderLanes.route(model) }
          watch_params
          watch_params(fake: true)
        end

        def validate_cell(cell)
          raise ArgumentError, "#{name}: no instrument #{cell.instrument.inspect}; the launcher runs #{INSTRUMENTS.keys.join(", ")}" unless INSTRUMENTS.key?(cell.instrument)
          raise ArgumentError, "#{name}: a #{cell.instrument} cell's n #{cell.n} is not cut by split #{cell.split}" unless cell.n.positive? && (cell.n % cell.split).zero?
          raise ArgumentError, "#{name}: a #{cell.instrument} cell names no objective" if cell.objectives.empty?

          cell.models.each { |model| model.start_with?("fake/") ? FakeBenchAdapter.route(model) : ProviderLanes.route(model) }
        end

        # The corpora the counterfactual reads are tracked extracts, and the door reader's register
        # sits beside the definition, which hashes it.
        def validate_stage0
          counterfactual = stage0["counterfactual"]
          if counterfactual
            unknown = counterfactual.fetch("corpus") - Corpus::SCRIPTS.keys
            raise ArgumentError, "#{name}: the counterfactual names no extract #{unknown.join(", ")}" if unknown.any?
          end
          door_reader = stage0["door_reader"]
          if door_reader && !File.file?(File.join(dir, door_reader.fetch("expected")))
            raise ArgumentError, "#{name}: the door reader's register #{door_reader.fetch("expected")} is not beside the definition"
          end
        end

        # A draw is named by its instrument, model, objective and sample alone, so two cells
        # registering one objective for one model would draw it twice under one name.
        def validate_draws
          named = cells.flat_map { |cell| cell.models.product(cell.objectives).map { |model, objective| [cell.instrument, model, objective] } }
          twice = named.tally.select { |_draw, count| count > 1 }.keys
          raise ArgumentError, "#{name}: registered twice: #{twice.map { |draw| draw.join(" ") }.join("; ")}" if twice.any?
        end
    end
  end
end
