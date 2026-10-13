require "digest"
require "shellwords"
require "yaml"
require_relative "docker_bases"
require_relative "expected"
require_relative "bench"

module E2E
  module Evals
    # THE AGENTS-ON-RAILS CORPUS, LOADED IN ITS OWN FORM (rails/ai-evals supplies the external
    # task-pass yardstick; this harness runs its task format). Their `tasks/<name>/` =
    # `instruction.md` (front-matter `name, description, difficulty, tags, category, rails_anchor`,
    # the body, and their canary GUID on a line of its own), `environment.patch` (applied with `git
    # apply` inside the app before the turn), `solution.patch` (a reference — never applied by the
    # runner), `verification_test.rb` (hidden; run inside the container after the graded surfaces
    # are restored); one frozen `bench.yml` (`environment{dockerfile, profiles, …}`, `agent{…}`,
    # `verifier{command, preverify, restore}`). Every task becomes a `Task` of family `rails`,
    # capability `rails.<rails_anchor>`, driver `plain`, verification true, strong tier only; THEIR
    # canary is passed through verbatim and asserted present in every instruction — never ours.
    #
    # VERIFICATION SEMANTICS ARE THEIRS: restore `verifier.restore` (`git
    # checkout -- <paths>` in the app), run `preverify` (the shipped suite
    # stays green), then the `command` with their `-report-lemans` flag
    # dropped — the exit status is the verdict (`E2E::Evals::Docker`
    # spells the argv of each; the RUN half proves them in a container).
    # No reach dimension: their instructions state the work and the
    # runner's tools are rho's; the reach columns read `—`.
    #
    # THROUGH THE ONE EVALS LANE: a task answers the same questions a mock-corpus task does —
    # `image` (its profile's app image, `Docker::IMAGES`), `runner_home?` true, `flags` `{}`,
    # `deadline_seconds` from their `agent.timeout`, `expected` with no reach — and the two
    # container hooks the lane calls in order: `prepare(daemon)` (`git apply` of the patch in the
    # app) and `verify_in(daemon, workdir:)` (their three steps). The task dir is mounted at
    # `/tests:ro` for the turn (the patch is read from there; the hidden test rides beside it —
    # their form, kept).
    #
    # Two readings of their config this loader ASSUMES until the RUN half
    # opens the real repo beside it (the sample fixture pins them):
    # the canary is a top-level `canary` key of `bench.yml`; the task's
    # image profile is the tag or category that names one of
    # `environment.profiles`, else the first profile listed.
    module AgentsOnRails
      FAMILY = "rails".freeze
      DRIVER = "plain".freeze
      TIERS = [Evals::Bench::STRONG].freeze
      WORKDIR = "/app".freeze
      # No reach, no success: their instruction states the work.
      NO_REACH = Expected.new(reach: nil, success: nil).freeze
      FILES = %w[instruction.md environment.patch solution.patch verification_test.rb].freeze
      REQUIRED = %w[name description difficulty tags category rails_anchor].freeze
      REPORT_FLAG = "-report-lemans".freeze
      CANARY = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
      FRONT_MATTER = /\A---\n(?<yaml>.*?)\n---\n(?<body>.*)\z/m
      ENV_CORPUS = "E2E_EVALS_RAILS_CORPUS".freeze

      Bench = Data.define(:path, :document, :digest) do
        def canary = document.fetch("canary")
        def environment = Hash(document["environment"])
        def dockerfile = environment["dockerfile"]
        def agent = Hash(document["agent"])
        def verifier = Hash(document["verifier"])
        def command = verifier.fetch("command")
        def preverify = verifier["preverify"]
        def restore = Array(verifier["restore"])
        def short_digest = digest[0, 12]

        # Their profiles as NAMES, whether the file maps them or lists them — a listed entry a mapping
        # carrying its name, or the name itself. Their sample lists names; the map, the listed mapping
        # and the bare name are readings this loader tolerates until their real repository is opened
        # (as the header's two assumptions are), each by its own arm, and a name that maps to no app
        # image is refused at load.
        def profiles
          raw = environment["profiles"]
          case raw
          when Hash then raw.keys.map(&:to_s)
          else Array(raw).map { |entry| profile_name(entry) }
          end
        end

        def profile_name(entry)
          case entry
          when Hash then entry.fetch("name").to_s
          else entry.to_s
          end
        end

        # The verifier's argv with the reporter flag dropped: the exit
        # status is the verdict here, and the flag names a reporter only
        # their unreleased harness has.
        def verifier_argv = Shellwords.split(command).reject { |word| word == REPORT_FLAG }
        def preverify_argv = preverify.to_s.strip.empty? ? nil : Shellwords.split(preverify)
        def restore_argv = restore.empty? ? nil : ["git", "checkout", "--", *restore]
      end

      Task = Data.define(:name, :description, :difficulty, :tags, :category, :rails_anchor, :canary, :profile,
                         :instruction, :dir, :bench) do
        def family = FAMILY
        def capability = "rails.#{rails_anchor}"
        def driver = DRIVER
        def flags = {}
        def compaction = "kernel"
        def runner_home? = true
        def verification = true
        def restore = []
        def turns = []
        def models = []
        def tiers = TIERS
        def on_tier?(tier) = tiers.include?(tier.to_s)
        def on_model?(_model) = true
        def optional_model?(_model) = false
        def runs_for(_model, runs) = runs
        def match?(glob) = File.fnmatch?(glob, name) || File.fnmatch?(glob, "#{FAMILY}/#{name}")
        def environment_patch = File.join(dir, "environment.patch")
        def solution_patch = File.join(dir, "solution.patch")
        def verification_test = File.join(dir, "verification_test.rb")
        # THEIR patience, in seconds (`agent.timeout`); the bench's 600 never.
        def deadline_seconds = Integer(bench.agent.fetch("timeout"))
        def expected = NO_REACH
        # The profile's app image; a profile off the map is refused by name
        # at load (`DockerBases.base_for`).
        def image = DockerBases.base_for(profile)
        def workdir = WORKDIR
        def tests_mount = dir
        # Their bases run as root with `/app` root-owned; the derived image
        # chowns it to uid 1000 and runs as it (the image's default user).
        def container_user = nil
        def prepare(daemon) = daemon.apply_environment!

        def verify_in(daemon, workdir: WORKDIR)
          daemon.verify!(bench)
        rescue StandardError => error
          { "pass" => false, "output" => "#{error.class}: #{error.message[0, 400]}" }
        end
      end

      Loaded = Data.define(:dir, :bench, :tasks) do
        def find(name) = tasks.find { |task| task.name == name } || raise(ArgumentError, "no Agents-on-Rails task #{name.inspect} under #{dir}")
        def select(glob) = tasks.select { |task| task.match?(glob) }
        def names = tasks.map(&:name)
        def anchors = tasks.map(&:rails_anchor).tally
      end

      module_function

      # `corpus_dir` is their checkout (E2E_EVALS_RAILS_CORPUS): `bench.yml`
      # at its root, `tasks/<name>/` beside it.
      def load(corpus_dir)
        bench = read_bench(File.join(corpus_dir, "bench.yml"))
        tasks_dir = File.join(corpus_dir, "tasks")
        raise ArgumentError, "Agents-on-Rails: #{tasks_dir} is not a directory" unless File.directory?(tasks_dir)

        dirs = Dir.children(tasks_dir).sort.map { |child| File.join(tasks_dir, child) }.select { |path| File.directory?(path) }
        Loaded.new(dir: corpus_dir, bench: bench, tasks: dirs.map { |task_dir| load_task(task_dir, bench: bench) })
      end

      def read_bench(path)
        raise ArgumentError, "Agents-on-Rails: #{path} is missing" unless File.file?(path)

        bytes = File.read(path, encoding: Encoding::UTF_8)
        document = Hash.try_convert(YAML.safe_load(bytes, permitted_classes: [], aliases: false)) or
          raise ArgumentError, "Agents-on-Rails: #{path} is not a mapping"
        raise ArgumentError, "Agents-on-Rails: #{path} names no canary" unless CANARY.match?(document["canary"].to_s)
        raise ArgumentError, "Agents-on-Rails: #{path} names no verifier.command" if document.dig("verifier", "command").to_s.strip.empty?
        raise ArgumentError, "Agents-on-Rails: #{path} names no agent.timeout" unless whole_number?(document.dig("agent", "timeout"))

        Bench.new(path: path, document: document, digest: Digest::SHA256.hexdigest(bytes))
      end

      # A whole number as written: `1800`, never `1800.0` or `"1800"`, which `Integer` alone would take.
      def whole_number?(value)
        integer = Integer(value, exception: false)
        !integer.nil? && value.eql?(integer)
      end

      def load_task(task_dir, bench:)
        name = File.basename(task_dir)
        missing = FILES.reject { |file| File.file?(File.join(task_dir, file)) }
        refuse(name, "is missing #{missing.join(", ")}") unless missing.empty?
        front, body = split(File.read(File.join(task_dir, "instruction.md"), encoding: Encoding::UTF_8), name)
        fields = fields_of(front, name)
        check!(fields, body, name, bench.canary)
        profile = profile_of(fields, bench)
        refuse(name, "profile #{profile.inspect} names no app image (#{DockerBases::IMAGES.keys.join(", ")})") unless
          DockerBases::IMAGES.key?(profile.to_s)
        Task.new(**fields.slice(*REQUIRED).transform_keys(&:to_sym), canary: bench.canary,
          profile: profile, instruction: body.strip, dir: task_dir, bench: bench)
      end

      def refuse(name, why) = raise(ArgumentError, "Agents-on-Rails task #{name}: #{why}")

      def split(source, name)
        match = FRONT_MATTER.match(source) || refuse(name, "instruction.md has no YAML front-matter")
        [match[:yaml], match[:body]]
      end

      def fields_of(front, name)
        Hash.try_convert(YAML.safe_load(front, permitted_classes: [], aliases: false)) ||
          refuse(name, "the front-matter is not a mapping")
      end

      def check!(fields, body, name, canary)
        missing = REQUIRED - fields.keys
        refuse(name, "front-matter is missing #{missing.join(", ")}") unless missing.empty?
        refuse(name, "name #{fields["name"].inspect} is not the directory's #{name.inspect}") unless fields["name"] == name
        refuse(name, "tags must be a list") if Array.try_convert(fields["tags"]).nil?
        refuse(name, "rails_anchor must be a word") unless fields["rails_anchor"].to_s.match?(/\A\w+\z/)
        refuse(name, "the instruction carries no line with the bench's canary #{canary}") unless
          body.lines.any? { |line| line.strip == canary }
      end

      def profile_of(fields, bench)
        profiles = bench.profiles
        return nil if profiles.empty?

        named = [*Array(fields["tags"]), fields["category"]].map(&:to_s).find { |word| profiles.include?(word) }
        named || profiles.first
      end
    end
  end
end
