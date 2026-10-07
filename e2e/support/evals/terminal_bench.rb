require "toml-rb"
require_relative "expected"
require_relative "bench"

module E2E
  module Evals
    # Load the configured Terminal-Bench task names from a local Harbor-format checkout at the
    # pinned commit. Instructions, container setup, timeout and hidden verifier remain the corpus's
    # own. This loader never fetches a checkout; the family is enabled only when E2E_EVALS_TB_CORPUS
    # names one.
    #
    # THEIR FORM, READ AS IT IS: `task.toml` at the pinned commit is
    # `version = "1.0"` with `[metadata]`, `[verifier]`, `[agent]`,
    # `[environment]` and NO `[task]` table; TB2 `main` and FrontierHarness's
    # copies are `schema_version = "1.1"` with `[task] name =
    # "terminal-bench/<dir>"` — a PREFIXED name, never the bare dir. So the
    # task's name is its DIRECTORY, and a `[task].name`, when present, must
    # equal `terminal-bench/<dir>` (refused by name otherwise). The
    # instruction the model gets is `instruction.md` VERBATIM — their form
    # carries no canary in it (the TB canary GUID sits in the Dockerfile and
    # the tests' comments), so the mock corpus's last-line rule never applies
    # here. `[agent].timeout_sec` is the run's deadline (THEIRS: 900 s on 17
    # of the 21, 1200 on two, 1800 on one, 600 on one — never the bench's
    # 600); `[verifier].timeout_sec` bounds the verifier; `[metadata].
    # difficulty` is a fact column only (all 21 are `medium`); `[environment].
    # docker_image` is the base the derived image builds FROM
    # (`alexgshaw/<name>:20251031`, single-manifest linux/amd64 on Docker Hub).
    #
    # VERIFICATION IS THEIRS: `tests/test.sh` runs inside the container as
    # ROOT with the network (it apt-installs curl, fetches uv from astral.sh
    # and pytest from PyPI), writes `/logs/verifier/reward.txt` — `1` or `0`
    # — and pass = the reward parses to a Float ≥ 1 (harbor's reward is a
    # float; absent or unparseable is red BY NAME, never a raise). The
    # `tests/` dir is copied into the container only AFTER the turn
    # (`docker cp`, harbor's shape) so the hidden check stays hidden from the
    # model's shell. No reach dimension: their instruction states the work
    # and the tools are rho's, so `reached` and `succeeded` are nil — "not
    # read", `—` on every reader — and task pass is the one number.
    #
    # The task names, dataset commit, model cells, sample counts and cost limits live in bench.yml.
    # This module only loads tasks and exposes the container and verification data the shared lane
    # consumes.
    module TerminalBench
      FAMILY = "terminal-bench".freeze
      DRIVER = "plain".freeze
      TIERS = Bench::TIERS
      ENV_CORPUS = "E2E_EVALS_TB_CORPUS".freeze
      INSTRUCTION = "instruction.md".freeze
      TASK_TOML = "task.toml".freeze
      TESTS_DIR = "tests".freeze
      TEST_SH = "test.sh".freeze
      NAME_PREFIX = "terminal-bench/".freeze
      # `version` (1.0, the pinned commit) or `schema_version` (1.1, main).
      VERSIONS = %w[1.0 1.1].freeze
      DIFFICULTIES = %w[easy medium hard].freeze
      # Their images run the agent as the image's default user — root — and several of the 21 assume
      # it (openssl-selfsigned-cert, kv-store-grpc's ports, db-wal-recovery, git-leak-recovery,
      # polyglot-c-py's apt installs); the verifier needs root too. The container runs as uid 0
      # (`docker run --user 0`); the image itself is built as uid 1000 like the rails family's (the
      # installer's guard reads BuildKit's RUN as no container, so a root install never builds) —
      # but its WorkingDir KEEPS HARBOR'S OWNER (`Docker.app_owner_for(container_user:)` reads this
      # uid as "the base's owner stands"; the recipe's `APP_OWNER=base`): a 1000-owned `/app/dclm`
      # under root made git refuse sanitize-git- repo's tree as "dubious ownership", so the tree is
      # byte-and- owner what harbor's agent sees.
      CONTAINER_USER = "0".freeze
      # No reach, no success: their instruction states the work.
      NO_REACH = Expected.new(reach: nil, success: nil).freeze

      # bench.yml's `terminal_bench` block, read whole: the names the loader
      # filters the checkout to, the dataset it must be, the two cells.
      Policy = Data.define(:dataset, :git_url, :commit, :names, :cell_models, :cell_runs, :optional_models, :optional_runs) do
        def self.of(bench)
          block = bench.terminal_bench
          cell = Hash(block["cell"])
          optional = Hash(block["optional_cell"])
          new(dataset: block.fetch("dataset").to_s, git_url: block.fetch("git_url").to_s, commit: block.fetch("commit").to_s,
            names: Array(block.fetch("tasks")).map(&:to_s), cell_models: Array(cell["models"]).map(&:to_s),
            cell_runs: Integer(cell.fetch("runs")), optional_models: Array(optional["models"]).map(&:to_s),
            optional_runs: Integer(optional.fetch("runs", 1)))
        end

        def models = cell_models + optional_models
        def runs_cap(model) = cell_models.include?(model) ? cell_runs : optional_runs
      end

      Task = Data.define(:name, :difficulty, :image, :deadline_seconds, :verifier_timeout_sec, :instruction, :dir, :policy) do
        def family = FAMILY
        def capability = "#{FAMILY}.#{name}"
        def driver = DRIVER
        def flags = {}
        def compaction = "kernel"
        # The tree the model works on is the container's: the lane pairs a
        # runner-mode rho inside it as the group's second home.
        def runner_home? = true
        def verification = true
        def restore = []
        def turns = []
        def tiers = TIERS
        def on_tier?(tier) = tiers.include?(tier.to_s)
        # Default-cell models run when selected. Optional-cell models run only when E2E_EVALS_MODELS
        # explicitly names them; models outside both cells are excluded.
        def models = policy.models
        def on_model?(model) = policy.cell_models.include?(model)
        def optional_model?(model) = policy.optional_models.include?(model)
        # The cell's n caps the selection's (`runs_per_task` stays 3; the
        # floor's cell is n=2, the optional one n=1).
        def runs_for(model, runs) = [runs, policy.runs_cap(model)].min
        # Their names share no prefix: `terminal-bench/*` selects the family.
        def match?(glob) = File.fnmatch?(glob, name) || File.fnmatch?(glob, "#{FAMILY}/#{name}")
        def expected = NO_REACH
        def tests_dir = File.join(dir, TESTS_DIR)
        # Read off the pulled base at run time (`docker image inspect`'s
        # WorkingDir: 20 tasks `/app`, sanitize-git-repo `/app/dclm`) — never
        # assumed here.
        def workdir = nil
        # Nothing is mounted at /tests for the turn: the hidden check is
        # copied in at verify time.
        def tests_mount = nil
        def container_user = CONTAINER_USER
        def prepare(_daemon) = nil

        # Their verifier, inside the container, as the lane reads it: a
        # raise is a red with the error as its output, never a raised lane.
        def verify_in(daemon, workdir:)
          daemon.verify_reward!(tests_dir: tests_dir, workdir: workdir, timeout: verifier_timeout_sec)
        rescue StandardError => error
          { "pass" => false, "output" => "#{error.class}: #{error.message[0, 400]}" }
        end
      end

      Loaded = Data.define(:dir, :tasks) do
        def find(name) = tasks.find { |task| task.name == name } || raise(ArgumentError, "no terminal-bench task #{name.inspect} under #{dir}")
        def select(glob) = tasks.select { |task| task.match?(glob) }
        def names = tasks.map(&:name)
      end

      module_function

      # `corpus_dir` is the harbor checkout's ROOT (E2E_EVALS_TB_CORPUS); the
      # bench's names are the filter — a name the checkout lacks is refused
      # by name (a wrong commit, a wrong dir), never silently absent.
      def load(corpus_dir, bench:)
        raise ArgumentError, "terminal-bench: #{corpus_dir.inspect} is not a directory (#{ENV_CORPUS} names the harbor checkout's root)" unless
          corpus_dir && File.directory?(corpus_dir)

        policy = Policy.of(bench)
        raise ArgumentError, "terminal-bench: bench.yml's terminal_bench.tasks names no task" if policy.names.empty?

        missing = policy.names.reject { |name| File.directory?(File.join(corpus_dir, name)) }
        raise ArgumentError, "terminal-bench: #{corpus_dir} lacks #{missing.join(", ")} (the checkout must be #{policy.dataset} at #{policy.commit})" unless
          missing.empty?

        Loaded.new(dir: corpus_dir, tasks: policy.names.map { |name| load_task(File.join(corpus_dir, name), policy: policy) })
      end

      def load_task(task_dir, policy:)
        name = File.basename(task_dir)
        instruction = File.read(path_of(task_dir, INSTRUCTION, name), encoding: Encoding::UTF_8)
        refuse(name, "#{INSTRUCTION} is empty") if instruction.strip.empty?
        path_of(task_dir, File.join(TESTS_DIR, TEST_SH), name)
        toml = parse(path_of(task_dir, TASK_TOML, name), name)
        check!(toml, name)
        Task.new(name: name, difficulty: toml.dig("metadata", "difficulty").to_s, image: toml.dig("environment", "docker_image"),
          deadline_seconds: seconds(toml.dig("agent", "timeout_sec")), verifier_timeout_sec: seconds(toml.dig("verifier", "timeout_sec")),
          instruction: instruction, dir: task_dir, policy: policy)
      end

      def refuse(name, why) = raise(ArgumentError, "terminal-bench task #{name}: #{why}")

      def path_of(task_dir, file, name)
        path = File.join(task_dir, file)
        refuse(name, "#{file} is missing") unless File.file?(path)
        path
      end

      # The real grammar: a file toml-rb cannot parse is refused with the
      # parser's own words, never read by a guess.
      def parse(path, name)
        Hash.try_convert(TomlRB.parse(File.read(path, encoding: Encoding::UTF_8))) || refuse(name, "#{TASK_TOML} is not a table")
      rescue TomlRB::Error => error
        refuse(name, "#{TASK_TOML} does not parse: #{error.message.lines.first.to_s.strip[0, 200]}")
      end

      # Every refusal names the key and the task.
      def check!(toml, name)
        version = (toml["schema_version"] || toml["version"]).to_s
        refuse(name, "#{TASK_TOML} version #{version.inspect} is not one of #{VERSIONS.join("|")}") unless VERSIONS.include?(version)
        declared = toml.dig("task", "name")
        refuse(name, "[task].name #{declared.inspect} is not #{(NAME_PREFIX + name).inspect}") unless declared.nil? || declared == NAME_PREFIX + name
        image = String.try_convert(toml.dig("environment", "docker_image"))
        refuse(name, "[environment].docker_image is missing") if image.to_s.strip.empty?
        refuse(name, "[agent].timeout_sec must be a positive number") unless positive?(toml.dig("agent", "timeout_sec"))
        refuse(name, "[verifier].timeout_sec must be a positive number") unless positive?(toml.dig("verifier", "timeout_sec"))
        difficulty = toml.dig("metadata", "difficulty")
        refuse(name, "[metadata].difficulty #{difficulty.inspect} is not one of #{DIFFICULTIES.join("|")}") unless
          difficulty.nil? || DIFFICULTIES.include?(difficulty)
      end

      def positive?(value)
        number = number_as_written(value)
        !number.nil? && number.positive?
      end

      # A number as harbor's files write it (task.toml, result.json) — its own Integer or its own
      # Float, never a String that parses as one; nil for anything else.
      def number_as_written(value)
        [Integer(value, exception: false), Float(value, exception: false)].find { |candidate| value.eql?(candidate) }
      end

      # Their seconds are floats (`900.0`); the lane's patience is whole.
      def seconds(value) = Float(value).ceil
    end
  end
end
