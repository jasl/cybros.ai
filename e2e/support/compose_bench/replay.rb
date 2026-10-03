require "json"
require "tempfile"
require_relative "../process_runner"
require_relative "executed"
require_relative "shape"
require_relative "tools"

module E2E
  module ComposeBench
    # THE TEXT BENCH'S KERNEL CHECK: the static reading scores a script on the harness's lowering
    # (`Shape`), and nothing else checked that lowering against the kernel it describes — the
    # executed reading's `agree!` runs only where a trace holds a plan. The replay lowers each script
    # both ways in ONE tree — that tree's evaluator, `Shape.lower` and `Compose::Lower` →
    # `Tasks::Compile` from a compose call's branch tip, inside a `bin/rails runner` on the tree's own
    # Nexus (`replay_kernel.rb`; the compile opens no database connection) — and requires the two to
    # be one graph under `Executed.same_graph?`: the same steps, waits and reads, a race read as its
    # exits, each step's reads in the order it reads them. A script the evaluator refuses has
    # nothing to compare; one the kernel refuses where the harness lowers a graph, or the other way
    # round, is a mismatch; one both refuse alike agrees without a graph compared, and the result
    # counts those apart (`compared`, `refused_alike`) so an agreement on refusals never passes for
    # a comparison. A stage is one node on both sides: the replay stops at the first expansion
    # boundary. The tool set is the batch's: a script is replayed under the tools its round
    # declared, so a batch holds scripts that declared one set.
    #
    # `root` names the tree whose kernel and harness are replayed, this one by default, so a launch
    # checks each arm of a with/without pair against its own kernel with one reader; `ordered: false`
    # compares each step's reads as a set, the rule a screen registers for a tree whose lowering
    # keeps no read order (`Screen::ReplayGate`).
    module Replay
      ROOT = File.expand_path("../../..", __dir__)
      RUNNER = File.expand_path("replay_kernel.rb", __dir__)
      # The kernel's boot and one compile per script: patience for a batch of the bench's size.
      TIMEOUT_SECONDS = 600

      # One script's replay: `built` false when the evaluator refused it; `compared` whether both
      # sides lowered a graph; `agrees` whether they are one graph (or refuse alike); `refusal` the
      # code both refused it with; `reason` says how they differ.
      Replayed = Data.define(:built, :compared, :agrees, :refusal, :reason)
      # The batch: how many scripts built, how many compared a graph on both sides, the refusal codes
      # both sides agreed on (tallied), and each one's replay in order.
      Result = Data.define(:replays) do
        def built = replays.count(&:built)
        def compared = replays.count(&:compared)
        def refused_alike = replays.select { |replay| replay.built && replay.refusal }.map(&:refusal).tally
        def mismatches = replays.each_with_index.select { |replay, _| replay.built && !replay.agrees }
        def agrees? = mismatches.empty?

        # The stamp's line: every count a reader needs to tell a comparison from an agreement on
        # refusals.
        def summary = "built #{built}, compared #{compared}, refused alike #{refused_alike.sum { |_, n| n }} " \
                      "#{refused_alike.to_h.inspect}, mismatches #{mismatches.size}"
      end

      module_function

      # `scripts`: `[{ "script" => …, "params" => … }]`; the tool set is the probe's by default.
      def call(scripts, root: ROOT, tool_names: Tools::NAMES, declarations: Tools.function_definitions, ordered: true)
        lines = lowered(scripts, root: root, tool_names: tool_names, declarations: declarations)
        Result.new(replays: lines.map { |line| compare(line, ordered: ordered) })
      end

      # The runner's lines, one per script in order: whether the evaluator built it, and each
      # lowering's graph or refusal — the kernel's as its payloads' keys, `input_from` and
      # `result_from`, for a reader that pins a plan to the kernel's compile of its script.
      def lowered(scripts, root: ROOT, tool_names: Tools::NAMES, declarations: Tools.function_definitions)
        lines = kernel(scripts, root: root, tool_names: tool_names, declarations: declarations)
        raise ArgumentError, "the replay answered #{lines.size} scripts of #{scripts.size}" unless lines.size == scripts.size

        lines
      end

      # One runner line — the harness's lowering and the kernel's, each a graph or a refusal — as
      # its replay; `ordered` whether each step's reads compare in order or as a set.
      def compare(line, ordered: true)
        return Replayed.new(built: false, compared: false, agrees: true, refusal: nil, reason: nil) unless line.fetch("built")

        harness = line.fetch("shape")
        kernel = line.fetch("kernel")
        if harness.key?("refusal") || kernel.key?("refusal")
          same = harness["refusal"] == kernel["refusal"]
          Replayed.new(built: true, compared: false, agrees: same, refusal: (harness["refusal"] if same),
            reason: (same ? nil : "the harness #{said(harness)} where the kernel #{said(kernel)}"))
        else
          one = shape_graph(harness)
          other = kernel_graph(kernel)
          same = Executed.same_graph?(one, other, ordered: ordered)
          Replayed.new(built: true, compared: true, agrees: same, refusal: nil,
            reason: (same ? nil : "the harness lowers #{Scoring.describe(one).inspect[0, 300]} where the kernel placed " \
                                  "#{Scoring.describe(other).inspect[0, 300]}"))
        end
      end

      def said(side) = side.key?("refusal") ? "refused #{side["refusal"]}" : "lowers a graph"

      def shape_graph(neutral)
        nodes = neutral.fetch("nodes").map do |node|
          Shape::Node.new(key: node.fetch("key"), kind: node.fetch("kind"), detached: false, reads: node.fetch("reads"),
            race: node["race"], tool: nil)
        end
        Shape::Graph.new(nodes: nodes, edges: neutral.fetch("edges").uniq)
      end

      # The kernel's payloads as the executed reading reads a plan: every node's reads its
      # `input_from` and its `result_from` with a race read as its exits, the positional ones kept
      # apart — whatever the node's kind, so a read the kernel handed a tool, an ask or a wait, which
      # the harness's rule (`Reads.of`) never makes, is a mismatch rather than dropped here.
      def kernel_graph(neutral)
        edges = neutral.fetch("edges").uniq
        joins = neutral.fetch("nodes").select { |node| node.fetch("task_kind") == "join_task" }.map { |node| node.fetch("key") }
        exits = joins.to_h { |join| [join, edges.filter_map { |from, to| from if to == join }] }
        nodes = neutral.fetch("nodes").map do |node|
          named = Shape.race_reads(exits, node.fetch("result_from"))
          Shape::Node.new(key: node.fetch("key"), kind: Executed::KINDS.fetch(node.fetch("task_kind")), detached: false,
            reads: node.fetch("input_from") | named, race: node["race"], tool: nil,
            positional: node.fetch("input_from") - named)
        end
        Shape::Graph.new(nodes: nodes, edges: edges)
      end

      # The runner over the tree's own Nexus, under its own bundle: every inherited bundler and Ruby
      # loader variable stripped, the test environment, the scripts on stdin, one JSON line back per
      # script.
      def kernel(scripts, root:, tool_names:, declarations:)
        nexus = File.join(root, "nexus")
        document = JSON.generate({ "root" => root, "scripts" => scripts, "tool_names" => tool_names, "declarations" => declarations })
        Tempfile.create("compose-replay") do |out|
          status = ProcessRunner.run(File.join(nexus, "bin", "rails"), "runner", RUNNER, env: runner_env(nexus), chdir: nexus,
            stdin: document, out: out, timeout: TIMEOUT_SECONDS)
          out.rewind
          text = out.read.to_s.force_encoding(Encoding::UTF_8)
          raise "the replay runner failed with status #{status.exitstatus.inspect}:\n#{text[-600..] || text}" unless status.success?

          text.lines.select { |line| line.start_with?("{") }.map { |line| JSON.parse(line) }
        end
      end

      def runner_env(nexus)
        ENV.keys.grep(/\ABUNDLE|\ARUBY(?:OPT|LIB)\z/).to_h { |key| [key, nil] }
          .merge("BUNDLE_GEMFILE" => File.join(nexus, "Gemfile"), "RAILS_ENV" => "test")
      end
      private_class_method :said, :shape_graph, :kernel_graph, :kernel, :runner_env
    end
  end
end
