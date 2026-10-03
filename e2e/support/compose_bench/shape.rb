require "json"
require_relative "../../../nexus/lib/nexus/canonical_json"
require_relative "../../../nexus/lib/nexus/size_bounds"
require_relative "../../../nexus/lib/nexus/step_bounds"
require_relative "../../../nexus/lib/nexus/compose/evaluator"
require_relative "../../../nexus/lib/nexus/compose/grammar"
require_relative "../../../nexus/lib/nexus/compose/reads"

module E2E
  module ComposeBench
    # THE LOWERING, IN THE HARNESS: the waits the kernel's `Tasks::Compile` derives
    # from a step tree — every task waits on the tip before it, a `parallel` contributes its
    # members' exits, a nested sequence runs under a local cursor — beside the read rule, which it
    # never restates: an authored step reads exactly what `Nexus::Compose::Reads` says it names,
    # and position hands it a wait, never a read. The compiler needs Rails; the bench scores a
    # model's script without booting it, so the cursor rule is restated here over the evaluator's
    # own `steps`, pinned by the harness test against the design's worked examples and checked
    # against the kernel's own lowering by `Replay`. The graph is over the script's OWN keys, from
    # an empty tip: the compose call the real envelope hangs under is the same edge on every script
    # and says nothing about what the model wrote. No step carries a WHEN word: the subgraph's
    # detachment rides the cursor — `lower(steps, detached:)` — and every node reads it, exactly as
    # `Compile` stamps `cursor.detached`. Beside the six verbs it lowers one harness-only step, an
    # `expansion`: a stage `Shape.inline` replaced by the steps the evaluator built for it,
    # contracted as the kernel splices an expansion into the plan.
    module Shape
      Tip = Data.define(:waits, :detached)
      # `tool` is the tool a `tool` node calls, nil on every other kind. `positional` are the reads
      # that did not come through a name — none on a script's lowering, whose reads are
      # `Reads.of`'s; on the plan that ran, the kernel's `input_from` on a step a compose call
      # placed, which no authored step can make, so any is a kernel finding. `credited` are the
      # reads the executed reading credits a model its stage fed (`Executed.stage_fed`) — never a
      # name the model's author wrote, so never counted as one.
      Node = Data.define(:key, :kind, :detached, :reads, :race, :tool, :positional, :credited) do
        def initialize(positional: [], credited: [], **) = super
        def model? = kind == "model"
        def foreground_model? = model? && !detached
        def launch? = LAUNCHES.include?(tool)
        def edits? = EDITS.include?(tool)
      end
      Graph = Data.define(:nodes, :edges) do
        def node(key) = nodes.find { |candidate| candidate.key == key }
        def keys = nodes.map(&:key)
        def reads = nodes.select(&:foreground_model?).to_h { |node| [node.key, node.reads] }
        def count(kind) = nodes.count { |node| node.kind == kind }
        # The graph with `gone` deleted, each with the waits into and out of it.
        def without(gone) = with(nodes: nodes.reject { |node| gone.include?(node.key) },
          edges: edges.reject { |from, to| gone.include?(from) || gone.include?(to) })

        # The graph with no wait out of a launch: what waited on one is read as waiting on its receipt,
        # never on what it launched (`LAUNCHES`). Every node and every read stays, a read of the launch
        # among them.
        def without_launch_waits
          launched = nodes.select(&:launch?).map(&:key)
          with(edges: edges.reject { |from, _| launched.include?(from) })
        end

        # The graph with `gone` contracted, one node at a time: what waited into it waits into what
        # waited on it, and a read of it is a read of what it read. Contraction keeps every wait the
        # other nodes had through it, so the order is free.
        def contract(gone)
          gone.reduce(self) do |graph, key|
            read = graph.node(key).reads
            into = graph.edges.filter_map { |from, to| from if to == key }
            out = graph.edges.filter_map { |from, to| to if from == key }
            through = ->(keys) { keys.flat_map { |source| source == key ? read : [source] }.uniq }
            graph.with(
              nodes: graph.nodes.filter_map do |node|
                unless node.key == key
                  node.with(reads: through.(node.reads), positional: through.(node.positional), credited: through.(node.credited))
                end
              end,
              edges: (graph.edges.reject { |from, to| from == key || to == key } + into.product(out)).uniq
            )
          end
        end
      end

      # A refusal the kernel's lowering makes after the evaluator built the steps: its code and the
      # sentence the model reads.
      Refusal = Data.define(:refusal, :detail)

      EMPTY = Tip.new(waits: [], detached: false)
      # The kernel's six (`Nexus::Compose::Grammar::VERBS`, pinned equal by the harness test): every
      # verb but `parallel` is a leaf.
      VERBS = %w[tool model ask wait script parallel].freeze
      EXPANSION = "expansion".freeze
      STEP_WORDS = [*VERBS, EXPANSION].freeze
      # The longest key a script may name (`Compose::Lower::MAX_SCRIPT_KEY`, pinned equal by the
      # harness test).
      MAX_SCRIPT_KEY = 32
      # The key a compose call's steps are namespaced under at the top level, where `Compose::Lower`
      # writes `<call's key>-<script key>` and the compiler reads that against the node key format:
      # a round's call key, spelled as the first round's first call is. Any call key of up to 31
      # characters reads the same, since the format's 64 hold it, the dash and a key of
      # `MAX_SCRIPT_KEY`. A stage's steps carry no namespace, so there the format reads the script's
      # key as written.
      CALL_KEY = "r1t0".freeze
      # The graph verbs a branch never inherits, in every spelling the alias tables give them (the
      # harness test pins them against `BranchTools::WITHHELD`): the kernel withholds by canonical,
      # and the harness holds only the names a style declared.
      WITHHELD = %w[compose task Agent Workflow].freeze
      # THE TOOLS THAT LAUNCH: a `start_process` call answers when its `wait_seconds` run out, its
      # process exits or a line matches its `wait_for`, and the process runs on past the answer — the
      # nearest spelling of the handle the references' background shells return at once. A step after
      # one is read as waiting on the launch and never on what it launched, whatever the budget: a
      # lenient reading, since a budget that outlasts the process waited all of it out. Its answer is
      # still the process's first output, so a step that reads it reads that output.
      LAUNCHES = %w[start_process].freeze
      # THE TOOLS THAT EDIT: a call that changes a file by what it is (the evals' trace names the
      # same two, pinned by the harness test). A shell command may or may not, and the picture reads
      # no command.
      EDITS = %w[edit write].freeze

      module_function

      def lower(steps, detached: false)
        lowering = Lowering.new
        lowering.place_all(Array(steps), EMPTY.with(detached: detached))
        lowering.graph
      end

      # What a step after `steps` waits on: the tip the lowering finishes at.
      def exits(steps) = Lowering.new.place_all(Array(steps), EMPTY).waits

      # A READ OF A RACE IS A READ OF ITS EXITS, THROUGH EVERY NESTING: a key of `map` (a race's join
      # => the exits its barrier waits on) stands for its exits, and an exit that is itself a race —
      # a nested race ending an arm — for its own, so a reader never reads a barrier; every other
      # key is itself. Once each, in order. The static lowering and the executed reading expand
      # with this one helper, each over its own map.
      def race_reads(map, keys) = keys.flat_map { |key| map.key?(key) ? race_reads(map, map.fetch(key)) : [key] }.uniq

      # The step tree rebuilt leaf by leaf: groups and nested sequences keep their shape, an
      # expansion is one leaf here, and the block answers each leaf's replacement step.
      def map_leaves(steps, &block)
        Array(steps).map do |step|
          sequence = Array.try_convert(step)
          if sequence
            map_leaves(sequence, &block)
          elsif step.key?("parallel")
            step.merge("parallel" => map_leaves(step["parallel"], &block))
          else
            verb = (step.keys & STEP_WORDS).first or raise ArgumentError, "no verb: #{step.keys.inspect}"
            yield verb, step.fetch(verb)
          end
        end
      end

      # The set a branch inherits: the round's names minus the graph verbs. A stage lowers under it,
      # and a `g.model`'s `tools` narrows it at any depth.
      def branch_names(tool_names) = tool_names - WITHHELD

      # THE REFUSALS THE KERNEL MAKES AND THE EVALUATOR CANNOT, in the kernel's own sentences and
      # order: the first `Refusal`, or nil. `Compose::Lower` walks the whole tree before
      # `Tasks::Compile` sees it, so a refusal of Lower's wins wherever it stands; then Compile's two
      # bounds on the whole batch; then Compile step by step — the first step that fails in placement
      # order, its key first and then the fields `step_refusal` names, in the compiler's order.
      # `tool_names` is the set the lowering declares — the round's at the top level, `branch_names`
      # inside a stage — and names the tools Lower's sentence lists; a `g.tool` names one of them,
      # and a `g.model`'s `tools` one the branch inherits. `stage:` is Lower's own switch: a stage's
      # keys carry no namespace.
      def lowering_refusal(steps, tool_names, stage: false)
        first_refusal(steps) { |verb, body| leaf_refusal(verb, body, tool_names) } ||
          batch_refusal(steps) || first_refusal(steps) { |verb, body| step_refusal(verb, body, stage) }
      end

      # The first leaf, in placement order, the block answers a `Refusal` for.
      def first_refusal(steps)
        refusals = []
        map_leaves(steps) { |verb, body| refusals << yield(verb, body) }
        refusals.compact.first
      end

      # One leaf in Lower's order: a `g.tool`'s name before its key, a `g.model`'s `tools` after
      # it, the keys named by `after:` and `results:` last.
      def leaf_refusal(verb, body, tool_names)
        tool = undeclared("g.tool", [body["name"].to_s], tool_names, tool_names) if verb == "tool"
        tools = undeclared("g.model", Array(body["tools"]), branch_names(tool_names), tool_names) if verb == "model"
        tool || too_long([body["key"]]) || tools || too_long([*body["after"], *body["results"]])
      end

      def undeclared(verb, wanted, inherited, tool_names)
        name = (wanted - inherited).first
        name.nil? ? nil : Refusal.new(refusal: "unknown_tool_name",
          detail: "#{verb}: #{name.inspect} is not one of your tools. You have: #{tool_names.join(", ")}")
      end

      def too_long(keys)
        key = keys.map(&:to_s).find { |candidate| candidate.length > MAX_SCRIPT_KEY }
        key.nil? ? nil : Refusal.new(refusal: "composed_key_too_long",
          detail: "#{key[0, MAX_SCRIPT_KEY]}… (max #{MAX_SCRIPT_KEY} characters)")
      end

      # Compile's bounds on the whole batch, before any step is placed: its leaves — every one a
      # group holds — against the kernel's bound, then the tree's JSON bytes. The compiler measures
      # the steps Lower wrote, which also carry each model step's inherited surface; the harness holds
      # only the steps the script built, so a batch that surface alone tips over is the kernel's alone
      # to refuse. A number JSON cannot spell (a script's `1/0`) is measured, not raised on: the
      # step's own check refuses it.
      def batch_refusal(steps)
        leaves = 0
        map_leaves(steps) { leaves += 1 }
        if leaves > Nexus::StepBounds::KERNEL_MAX_TASKS_PER_REQUEST
          compiled("too_many_steps")
        elsif JSON.generate(steps, allow_nan: true).bytesize > Nexus::StepBounds::MAX_TASKS_PAYLOAD_BYTES
          compiled("steps_payload_too_large")
        end
      end

      # One step in the compiler's order: its own key first, against the node key format as Lower
      # writes it; then the fields a built script can carry that the compiler checks — the row
      # store's own predicate on a tool's input, an ask's options and a stage's source and params;
      # U+0000 itself in a prompt or instructions, where the compiler reads the codepoint and not the
      # predicate; the byte bounds on a tool's input and a stage's source; a blank source or an empty
      # instructions; the task a wait observes, a key never namespaced.
      def step_refusal(verb, body, stage)
        key = body.fetch("key")
        code = key_code(stage ? key : "#{CALL_KEY}-#{key}") ||
          case verb
          when "tool" then tool_code(body["input"] || {})
          when "ask" then text_code("invalid_prompt", body["prompt"]) || options_code(body["options"])
          when "model" then text_code("invalid_prompt", body["prompt"]) || instructions_code(body["instructions"])
          when "script" then script_code(body.fetch("script"), body["params"] || {})
          when "wait" then key_code(body.fetch("task"))
          else nil
          end
        code && compiled(code, key)
      end

      def key_code(key) = ("invalid_task_key" unless Nexus::StepBounds::NODE_KEY_FORMAT.match?(key))

      def tool_code(input)
        if !Nexus::CanonicalJson.storable?(input)
          "invalid_tool_input"
        elsif !Nexus::SizeBounds.json_within?(Nexus::StepBounds::TOOL_INPUT_BOUND, input)
          "tool_input_too_large"
        end
      end

      def text_code(code, text) = (code if text.include?(Nexus::CanonicalJson::UNSTORABLE_CODEPOINT))

      def options_code(options) = ("invalid_ask_options" unless options.nil? || Nexus::CanonicalJson.storable?(options))

      def instructions_code(instructions)
        if instructions.nil?
          nil
        elsif instructions.empty?
          "invalid_instructions"
        else
          text_code("invalid_instructions", instructions)
        end
      end

      def script_code(source, params)
        if source.strip.empty?
          "script_required"
        elsif source.bytesize > Nexus::Compose::Evaluator::MAX_SOURCE_BYTES
          "script_too_large"
        elsif !Nexus::CanonicalJson.storable?(source)
          "invalid_script"
        elsif !Nexus::CanonicalJson.storable?(params)
          "invalid_script_params"
        end
      end

      # A refusal Compile makes, in the sentence the compose call settles with: its code and the
      # script's own key for the step it names, none for a bound on the whole batch. The kernel adds
      # the step's line from the evaluator's line tree, which a step tree does not carry.
      def compiled(code, key = nil)
        error = { "code" => code, "step" => key }.compact
        Refusal.new(refusal: code, detail: "The composed graph was refused:\n#{JSON.pretty_generate([error])}")
      end
      private_class_method :first_refusal, :leaf_refusal, :undeclared, :too_long, :batch_refusal, :step_refusal,
        :key_code, :tool_code, :text_code, :options_code, :instructions_code, :script_code, :compiled

      class Lowering
        def initialize
          @nodes = []
          @edges = []
          @race_exits = {}
        end

        def graph = Graph.new(nodes: @nodes, edges: @edges.uniq)

        def place_all(steps, cursor)
          steps.reduce(cursor) { |tip, step| place(step, tip) }
        end

        private

          def place(step, cursor)
            fields = Hash.try_convert(step) or raise ArgumentError, "not a step: #{step.inspect}"
            verb = (fields.keys & STEP_WORDS).first or raise ArgumentError, "no verb: #{fields.keys.inspect}"
            case verb
            when "parallel" then place_parallel(fields, cursor)
            when EXPANSION then place_expansion(fields.fetch(verb), cursor)
            else place_leaf(verb, fields.fetch(verb), cursor)
            end
          end

          # Every leaf becomes what the next step waits on, and reads what `Reads.of` says its verb
          # reads of the results it names — a model or a script its `results:`, a tool, an ask or a
          # wait nothing — never what ran before it. `after:` and `results:` wait on every key they
          # name (`Compile`'s `@extra_waits`) — a race's key on its join alone. Detachment is the
          # cursor's, never a step's.
          def place_leaf(verb, body, cursor)
            key = body.fetch("key")
            results = Array(body["results"])
            reads = Shape.race_reads(@race_exits, Nexus::Compose::Reads.of(verb, results))
            emit(Node.new(key: key, kind: verb, detached: cursor.detached, reads: reads, race: nil,
              tool: (body["name"] if verb == "tool")), cursor, references: Array(body["after"]) | results)
            cursor.with(waits: [key])
          end

          # A group's members are placed from its entry, each a fresh start; the group hands the
          # step after it the members' exits to wait on and nothing to read. A race adds the one
          # barrier the kernel places, and a READ OF A RACE IS A READ OF ITS EXITS — what the
          # barrier waits on, the steps its selection is drawn from
          # (`TaskResultProjection.referenced`), a nested race's own in its place
          # (`Shape.race_reads`) — so a step naming the race reads what a step naming every exit
          # would, and waits on the join where that one waits on every exit.
          def place_parallel(fields, cursor)
            exits = Array(fields["parallel"]).reduce([]) { |found, member| found | place_member(member, cursor).waits }
            ends = fields["until"]
            return cursor.with(waits: exits) if ends.nil? || ends == "all"

            # The builder minted the race's key, the name a later reference carries; a race
            # without one is the builder's defect, as it is `Compose::Lower`'s.
            join = fields.fetch("key")
            @nodes << Node.new(key: join, kind: "join", detached: cursor.detached, reads: [], race: ends, tool: nil)
            exits.each { |exit| @edges << [exit, join] }
            @race_exits[join] = exits
            cursor.with(waits: [join])
          end

          # The kernel places an expansion from a tip that waits on the stage, then hands the
          # stage's readers its final leaf (`Tasks::Append::Splice`). With the stage contracted,
          # the expansion's roots wait on what the stage waited on — the tip and its `after:` —
          # its steps read only what they name among one another, and the next step waits on the
          # final leaf, reading it only where it named the stage.
          def place_expansion(body, cursor)
            entry = EMPTY.with(waits: cursor.waits | Array(body["after"]), detached: cursor.detached)
            cursor.with(waits: place_all(body.fetch("steps"), entry).waits)
          end

          def place_member(member, entry)
            sequence = Array.try_convert(member)
            sequence ? place_all(sequence, entry) : place(member, entry)
          end

          def emit(node, cursor, references: [])
            @nodes << node
            cursor.waits.each { |wait| @edges << [wait, node.key] }
            references.each { |source| @edges << [source, node.key] }
          end
      end
    end
  end
end
