require "json"
require "tempfile"
require_relative "../../../nexus/lib/nexus/compose/evaluator"
require_relative "../../../nexus/lib/nexus/compose/grammar"
require_relative "../../../nexus/lib/nexus/compose/reads"
require_relative "../process_runner"
require_relative "tools"

module E2E
  module ComposeBench
    # WHAT COMES BACK TO THE CALLER, read two ways and compared: the pure rule over a plan before
    # anything ran (`Nexus::Compose::Reads.unread` over the script's own steps — `unread`), and the
    # kernel's rows for the same plan (`delivery_kernel.rb`, on the tree's own Nexus and test
    # database): the waited head's added reads, and the set the wake delivers once every row settled.
    # The pure rule's four consumers are what a plan holds before it runs: `named` every step's
    # `results:`, `members` every step placed in a race's arms at any depth (a nested race's barrier
    # among them), and nothing inside a stage or replaced by an expansion, since nothing has
    # expanded — the rows' loader decides those once the plan runs. A race is its barrier's key on
    # both sides, before its selection is read.
    #
    # `replay` needs the tree's test databases: `env` names its primary and cable databases with
    # RAILS_TEST_APP_DB_NAME and RAILS_TEST_CABLE_DB_NAME, since the runner writes rows in a rollback.
    module Delivery
      RUNNER = File.expand_path("delivery_kernel.rb", __dir__)
      ROOT = File.expand_path("../../..", __dir__)
      TIMEOUT_SECONDS = 600
      DATABASES = %w[RAILS_TEST_APP_DB_NAME RAILS_TEST_CABLE_DB_NAME].freeze

      # One script's comparison: `pure` the rule's set in placement order, `head` and `settled` the
      # rows' two sets, `agrees` whether all three are one set; nil sets when a lowering refused it.
      Compared = Data.define(:built, :pure, :head, :settled, :agrees)
      # The batch: each comparison in order, the kernel's bound on what one head may read, and the
      # size of each plan's set — the flood's size, offline.
      Result = Data.define(:comparisons, :bound) do
        def mismatches = comparisons.each_with_index.select { |comparison, _| comparison.built && !comparison.agrees }
        def agrees? = mismatches.empty?
        def sizes = comparisons.select(&:built).map { |comparison| comparison.pure.size }
        def within_bound? = sizes.all? { |size| size <= bound }
        def distribution = sizes.tally.sort.to_h
      end

      module_function

      # THE PURE RULE over the evaluator's steps: what no step of the plan reads, in placement order.
      def unread(steps)
        plan = { keys: [], named: [], members: [] }
        walk(Array(steps), plan, in_race: false)
        Nexus::Compose::Reads.unread(plan[:keys], named: plan[:named], members: plan[:members], internal: [], retired: [])
      end

      # Each script's plan read both ways; `tool_names` and `declarations` are the set the scripts'
      # round declared.
      def replay(scripts, env:, root: ROOT, tool_names: Tools::NAMES, declarations: Tools.function_definitions)
        lines = kernel(scripts, env: env, root: root, tool_names: tool_names, declarations: declarations)
        raise ArgumentError, "the delivery runner answered #{lines.size} scripts of #{scripts.size}" unless lines.size == scripts.size

        comparisons = scripts.zip(lines).map { |entry, line| compare(entry, line, tool_names) }
        Result.new(comparisons: comparisons, bound: lines.filter_map { |line| line["bound"] }.first)
      end

      def compare(entry, line, tool_names)
        unless line.fetch("built") && !line.key?("refusal")
          return Compared.new(built: false, pure: nil, head: nil, settled: nil, agrees: true)
        end

        built = Nexus::Compose::Evaluator.call(script: entry.fetch("script").to_s, params: entry["params"] || {}, tool_names: tool_names)
        pure = unread(built.steps)
        head = line.fetch("head")
        settled = line.fetch("settled")
        Compared.new(built: true, pure: pure, head: head, settled: settled,
          agrees: pure.sort == head.sort && pure.sort == settled.sort)
      end

      # A leaf's key is placed where it stands and its `results:` are named; a group's members are
      # placed from its entry; a race's members — every leaf and barrier in its arms, at any depth —
      # are its arms', and its own barrier is placed after them.
      def walk(steps, plan, in_race:)
        steps.each do |step|
          sequence = Array.try_convert(step)
          if sequence
            walk(sequence, plan, in_race: in_race)
          elsif step.key?("parallel")
            racing = !step["until"].nil? && step["until"] != "all"
            Array(step["parallel"]).each { |member| walk([member], plan, in_race: in_race || racing) }
            place(step.fetch("key"), plan, in_race: in_race) if racing
          else
            verb = (step.keys & Nexus::Compose::Grammar::VERBS).first or raise ArgumentError, "no verb: #{step.keys.inspect}"
            body = step.fetch(verb)
            place(body.fetch("key"), plan, in_race: in_race)
            plan[:named].concat(Nexus::Compose::Reads.of(verb, body["results"]))
          end
        end
      end

      def place(key, plan, in_race:)
        plan[:keys] << key
        plan[:members] << key if in_race
      end

      # The runner over the tree's own Nexus, under its own bundle, on the database `env` names.
      def kernel(scripts, env:, root:, tool_names:, declarations:)
        missing = DATABASES - env.keys
        raise ArgumentError, "the delivery runner writes rows: name the tree's test database (#{missing.join(", ")})" if missing.any?

        nexus = File.join(root, "nexus")
        document = JSON.generate({ "scripts" => scripts, "tool_names" => tool_names, "declarations" => declarations })
        Tempfile.create("compose-delivery") do |out|
          status = ProcessRunner.run(File.join(nexus, "bin", "rails"), "runner", RUNNER, env: runner_env(nexus, env), chdir: nexus,
            stdin: document, out: out, timeout: TIMEOUT_SECONDS)
          out.rewind
          text = out.read.to_s.force_encoding(Encoding::UTF_8)
          raise "the delivery runner failed with status #{status.exitstatus.inspect}:\n#{text[-600..] || text}" unless status.success?

          text.lines.select { |line| line.start_with?("{") }.map { |line| JSON.parse(line) }
        end
      end

      def runner_env(nexus, env)
        ENV.keys.grep(/\ABUNDLE|\ARUBY(?:OPT|LIB)\z/).to_h { |key| [key, nil] }
          .merge("BUNDLE_GEMFILE" => File.join(nexus, "Gemfile"), "RAILS_ENV" => "test").merge(env.slice(*DATABASES))
      end
      private_class_method :compare, :walk, :place, :kernel, :runner_env
    end
  end
end
