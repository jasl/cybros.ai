require "yaml"
require_relative "../fixture_project"
require_relative "../gallery/shapes"
require_relative "seed"
require_relative "expected"
require_relative "terminal_bench"
require_relative "agents_on_rails"
require_relative "bench"
# The readers a task file names at its top level (`Claims::Question`, `Coverage`, `DOOR_FACTS`):
# the corpus evaluates the files, so it loads what they name — `rake evals` builds its run list from
# here before any lane loads the rest.
require_relative "claims"
require_relative "coverage"
require_relative "door_facts"

module E2E
  module Evals
    # ONE TASK OF THE CORPUS: `tasks/<family>-<name>/` = `instruction.md` (YAML front-matter, then
    # the text the model gets — its LAST line the bench's canary), `environment/` (files, written
    # under the project before the turn) and/or `environment.rb` (a lambda over a `Seed`, for
    # generated content), `verification.rb` (hidden: a lambda over `(project, seed)` answering
    # `{pass:, output:}`, run in the lane process after the graded surfaces are restored — never
    # inside the loop), `expected.rb` (an `Expected`: the reach / success / conduct predicates over
    # a `Trace`), `RATIONALE.md` (what it measures, which seed it converts, what a red means). The
    # loader refuses what is missing BY NAME.
    Task = Data.define(:name, :family, :capability, :difficulty, :tags, :canary, :driver, :flags, :daemon,
                       :deadline_seconds, :verification, :restore, :tiers, :source, :turns, :policy, :models,
                       :instruction, :dir, :static_files, :generator, :expected, :verifier) do
      def files(seed) = static_files.merge(generator ? generator.call(seed) : {})

      def compaction = daemon.fetch("compaction", "kernel")

      def runner_home? = daemon["runner_home"] == true

      def on_tier?(tier) = tiers.include?(tier.to_s)

      # `models` narrows a tier to named ids (the long session on glm-5.3 alone); empty means every
      # model of the task's tiers.
      def on_model?(model) = models.empty? || models.include?(model)

      # A glob over the name, or over `family/name` — a family whose names
      # share no prefix (terminal-bench's 21) is selected as `terminal-bench/*`.
      def match?(glob) = File.fnmatch?(glob, name) || File.fnmatch?(glob, "#{family}/#{name}")

      # THE DUCK INTERFACE THE LANE DRIVES: a mock corpus task runs on the host — no image, no
      # optional model, the selection's n as it is. The container families answer the same questions
      # differently (`TerminalBench::Task`, `AgentsOnRails::Task`).
      def image = nil
      def optional_model?(_model) = false
      def runs_for(_model, runs) = runs

      # A fixture file that opens with a shebang is a script the instruction
      # runs by path (`bin/rails test`, `bin/probe alpha`): written
      # executable, the one thing FixtureProject.write does not know.
      # FixtureProject.write deletes nothing, so a directory that exists
      # would hand this run whatever an earlier run left in it: refused.
      def write_environment(home, dirname, seed)
        root = File.join(home, dirname)
        raise Errno::EEXIST, "#{root}: every run writes its fixture into a directory of its own" if File.exist?(root)

        project = E2E::FixtureProject.write(home, dirname, files(seed))
        # An EMPTY environment still needs its directory (the gallery's
        # `mkdir_p` first, `live_gallery_test.rb:134`): the daemon's
        # `/environment` refuses a root that is not a directory
        # (`not_a_directory`), and the tools would stay on the last project.
        FileUtils.mkdir_p(project.root)
        project.files.each { |path, contents| File.chmod(0o755, File.join(project.root, path)) if contents.start_with?("#!") }
        project
      end

      # The graded surfaces first — a model that edited the specification
      # is judged against the specification — then the hidden checks. A
      # verifier that raises is a red with its error as the output, never
      # a raised lane.
      def verify(project, seed)
        restore.each do |path|
          full = File.join(project.root, path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, project.files.fetch(path))
        end
        answer = Hash(verifier.call(project, seed))
        { "pass" => answer["pass"] == true, "output" => answer["output"].to_s }
      rescue StandardError => error
        { "pass" => false, "output" => "#{error.class}: #{error.message[0, 400]}" }
      end
    end

    module Corpus
      DIR = File.expand_path("../../evals/tasks", __dir__)
      REQUIRED = %w[name family capability difficulty tags canary driver flags daemon deadline_seconds verification
                    restore tiers source].freeze
      # `turns`: the person's later turns, in order, for a driver that says
      # them (`handoff`, `say_second_turn`); `policy`: the pump's, for
      # `pump`; `models`: a narrowing of the tiers to named ids.
      OPTIONAL = { "turns" => [], "policy" => "approve_all", "models" => [] }.freeze
      # The lanes' drivers moved (V1) plus the three V2 tasks needed and no lane had:
      # `settle_receipts` (a plain turn, then every loop the receipts woke — the workflow family and
      # task-fan-five), `memory_scope` (the steward's own door and a second workspace's reply,
      # live_memory_scopes' script) and `processes` (the person's half of live_processes: list, read
      # the log, kill, prove the port free). `spawn_reply`: a detached spawn's child reply — the
      # say_second_turn twin keyed on the `spawn` row and the `child` origin — placed before the V2
      # tail.
      DRIVERS = %w[plain answer_ask until say_second_turn brake compact_queued_round halting_loop handoff pump
                   spawn_reply settle_receipts memory_scope processes].freeze
      DIFFICULTIES = %w[easy medium hard].freeze
      TIERS = Bench::TIERS
      DAEMON_KEYS = %w[compaction runner_home].freeze
      COMPACTIONS = %w[kernel delegate].freeze
      FLAG_KEYS = %w[approval until attempts compose].freeze
      FRONT_MATTER = /\A---\n(?<yaml>.*?)\n---\n(?<body>.*)\z/m

      Loaded = Data.define(:dir, :tasks) do
        def find(name) = tasks.find { |task| task.name == name } || raise(ArgumentError, "no evals task #{name.inspect} under #{dir}")

        def select(glob) = tasks.select { |task| task.match?(glob) }

        def names = tasks.map(&:name)

        def families = tasks.map(&:family).uniq
      end

      module_function

      def load(dir = DIR, canary:)
        dirs = Dir.children(dir).sort.map { |child| File.join(dir, child) }.select { |path| File.directory?(path) }
        Loaded.new(dir: dir, tasks: dirs.map { |task_dir| load_task(task_dir, canary: canary) })
      end

      # THE WHOLE RUN LIST ("no evals_external twin"): this corpus plus each container family the
      # environment names — terminal-bench under `E2E_EVALS_TB_CORPUS`, Agents-on-Rails under
      # `E2E_EVALS_RAILS_CORPUS` — as ONE `Loaded`, so `Plan.build`, `rake evals_tasks` and the lane
      # see every family by its glob. Unset, the families are absent: a `rake "evals[*]"` never
      # becomes docker-bound by accident.
      def load_all(bench:, env: ENV)
        tasks = load(canary: bench.canary).tasks
        tb = env[TerminalBench::ENV_CORPUS].to_s
        tasks += TerminalBench.load(tb, bench: bench).tasks unless tb.empty?
        rails = env[AgentsOnRails::ENV_CORPUS].to_s
        tasks += AgentsOnRails.load(rails).tasks unless rails.empty?
        Loaded.new(dir: DIR, tasks: tasks)
      end

      def load_task(task_dir, canary:)
        name = File.basename(task_dir)
        front, body = split(read(task_dir, "instruction.md", name), name)
        fields = fields_of(front, name)
        check!(fields, body, name, canary)
        Task.new(
          **fields.slice(*REQUIRED, *OPTIONAL.keys).transform_keys(&:to_sym),
          instruction: body.strip, dir: task_dir,
          static_files: static_files(task_dir), generator: generator(task_dir, name),
          expected: expected(task_dir, name), verifier: verifier(task_dir, name, fields.fetch("verification"))
        )
      end

      def refuse(name, why) = raise(ArgumentError, "evals task #{name}: #{why}")

      def read(task_dir, file, name) = File.read(path_of(task_dir, file, name), encoding: Encoding::UTF_8)

      def split(source, name)
        match = FRONT_MATTER.match(source) || refuse(name, "instruction.md has no YAML front-matter")
        [match[:yaml], match[:body]]
      end

      def fields_of(front, name)
        parsed = Hash.try_convert(YAML.safe_load(front, permitted_classes: [], aliases: false)) ||
          refuse(name, "the front-matter is not a mapping")
        OPTIONAL.merge(parsed)
      end

      # Every refusal names the field and the task, so an author reads what
      # to add rather than that something is wrong.
      def check!(fields, body, name, canary)
        missing = REQUIRED - fields.keys
        refuse(name, "front-matter is missing #{missing.join(", ")}") unless missing.empty?
        refuse(name, "name #{fields["name"].inspect} is not the directory's #{name.inspect}") unless fields["name"] == name
        refuse(name, "difficulty #{fields["difficulty"].inspect} is not one of #{DIFFICULTIES.join("|")}") unless
          DIFFICULTIES.include?(fields["difficulty"])
        refuse(name, "driver #{fields["driver"].inspect} is not one of #{DRIVERS.join(", ")}") unless
          DRIVERS.include?(fields["driver"])
        refuse(name, "canary #{fields["canary"].inspect} is not the bench's #{canary}") unless fields["canary"] == canary
        refuse(name, "the instruction's last line is not the canary") unless body.strip.lines.last.to_s.strip == canary
        check_shapes!(fields, name)
      end

      # The front-matter is YAML an author wrote: each field is read through the conversion its shape
      # names (`Hash.try_convert`, `Array.try_convert`, `String.try_convert` — nil for anything else)
      # and refused by its own sentence when that conversion finds nothing.
      def check_shapes!(fields, name)
        refuse(name, "tags must be a list") if Array.try_convert(fields["tags"]).nil?
        flags = Hash.try_convert(fields["flags"])
        refuse(name, "flags must be a mapping of #{FLAG_KEYS.join(", ")}") unless flags && (flags.keys - FLAG_KEYS).empty?
        daemon = Hash.try_convert(fields["daemon"])
        refuse(name, "daemon must be a mapping of #{DAEMON_KEYS.join(", ")}") unless daemon && (daemon.keys - DAEMON_KEYS).empty?
        refuse(name, "daemon.compaction must be one of #{COMPACTIONS.join("|")}") unless
          COMPACTIONS.include?(fields["daemon"].fetch("compaction", "kernel"))
        refuse(name, "deadline_seconds must be a positive integer") unless positive_integer?(fields["deadline_seconds"])
        refuse(name, "verification must be true or false") unless [true, false].include?(fields["verification"])
        refuse(name, "restore must be a list of paths") if Array.try_convert(fields["restore"]).nil?
        tiers = Array.try_convert(fields["tiers"])
        refuse(name, "tiers must be a non-empty subset of #{TIERS.join(", ")}") unless
          tiers && !tiers.empty? && (tiers - TIERS).empty?
        refuse(name, "source must name the seed as file:line") unless fields["source"].to_s.match?(/\S:\d+/)
        refuse(name, "turns must be a list of strings") unless strings?(fields["turns"])
        refuse(name, "models must be a list of model ids") unless strings?(fields["models"])
      end

      # A whole number as written: `600`, never `600.0` or `"600"`, which `Integer` alone would take.
      def positive_integer?(value)
        integer = Integer(value, exception: false)
        !integer.nil? && value.eql?(integer) && integer.positive?
      end

      def strings?(value)
        list = Array.try_convert(value)
        !list.nil? && list.all? { |item| String.try_convert(item) }
      end

      def static_files(task_dir)
        root = File.join(task_dir, "environment")
        return {} unless File.directory?(root)

        Dir.glob("**/*", File::FNM_DOTMATCH, base: root).select { |rel| File.file?(File.join(root, rel)) }.sort
          .to_h { |rel| [rel, File.read(File.join(root, rel), encoding: Encoding::UTF_8)] }
      end

      # AN EVALUATED TASK FILE's value is the file's own construction, and its class is the whole
      # question the refusal asks — no conversion names a lambda or an Expected (`to_proc` would take
      # a Hash) — so it is read by pattern. The parentheses are load-bearing: unparenthesized, `in`
      # takes the modifier's whole condition and the arity check is silently dropped.
      def generator(task_dir, name)
        path = File.join(task_dir, "environment.rb")
        return nil unless File.file?(path)

        generator = evaluate(path)
        refuse(name, "environment.rb must evaluate to a lambda over a Seed") unless (generator in Proc) && generator.arity == 1
        generator
      end

      def expected(task_dir, name)
        expected = evaluate(path_of(task_dir, "expected.rb", name))
        refuse(name, "expected.rb must evaluate to an E2E::Evals::Expected, got #{expected.class}") unless expected in Expected
        expected
      end

      def verifier(task_dir, name, verification)
        return nil unless verification

        verifier = evaluate(path_of(task_dir, "verification.rb", name))
        refuse(name, "verification.rb must evaluate to a lambda over (project, seed)") unless (verifier in Proc) && verifier.arity == 2
        verifier
      end

      def path_of(task_dir, file, name)
        path = File.join(task_dir, file)
        refuse(name, "#{file} is missing") unless File.file?(path)
        path
      end

      # A task file is Ruby evaluated here, so `Expected`, `Gallery` and
      # `Seed` resolve as they do in this module; the path rides along so
      # a refusal names the file.
      def evaluate(path)
        eval(File.read(path, encoding: Encoding::UTF_8), binding, path, 1) # rubocop:disable Security/Eval
      end
    end
  end
end
