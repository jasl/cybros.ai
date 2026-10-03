require_relative "../gallery/shapes"
require_relative "scoring"
require_relative "shape"

module E2E
  module ComposeBench
    # THE EXECUTED READING: the picture scored on the plan the kernel placed under a compose call,
    # read off the graph route, instead of on the script text. The static lowering cannot see what a
    # `g.script` stage places at run time; the route can. The plan is the call's placements by the
    # kernel's own ownership mark (`Gallery.placed_by`). Every other node the route shows under it — a
    # member model's own rounds and tool calls — folds into the member it hangs under, so a
    # member's continuation named in a wait or a read is that member.
    #
    # Each script stage is read by what became of it. A stage that expanded hands what waited into it
    # to the roots it placed, outermost first; its own edges to its consumers go, since the kernel's
    # splice already made each consumer wait on the expansion's tail. A stage that placed nothing
    # and did not complete — it failed, or lost a race — computed nothing, and is contracted
    # (`Shape::Graph#contract`): what waited into it waits into what waited on it, and a read of it
    # is a read of what it read. A stage that completed and placed nothing computed a VALUE, and it
    # stays a `script` node reading what it read, whoever consumes it; the picture decides what it
    # is (`Picture`): the step a label admits a script for (O7's normaliser reading its own fetch,
    # O7's merge, O3's winner), the plan's answer where nothing waits on or reads it, and otherwise
    # transparent (`Plan#transparent`) — contracted as a stage that computed nothing is, which is how
    # a tag stage at a race arm's tail hands the race its probe.
    #
    # A model's reads are the kernel's (`input_from` and `result_from`), and so are a stage's; what
    # came through `input_from` and not through a name is positional (`Shape::Node#positional`),
    # which no step a compose call places can read, so the picture's `over_read_positional` on this
    # reading is a kernel finding. A tool has none of its own: its input is what the stages above it
    # decided, on what they read — a stage decides from its own results, and hands data to a stage
    # it places through that stage's `params` — so a tool a stage placed reads what every stage it
    # hangs under read, up to the call. A MODEL A STAGE FED is read the same way where the graph can
    # tell: the stage handed it nothing through the kernel, and the values it wrote into the
    # prompt came from what it read — so the one model step a stage placed, reading nothing the
    # kernel handed it, is credited with what its own stage read (`stage_fed`, on the record),
    # carried apart from any name (`Shape::Node#credited`), so a credit that over-reads is
    # `stage_fed` and never a name read too many; a stage that placed several model steps could
    # have written any of its values into any of their prompts, so those read nothing and the
    # picture names them `stage_fed`, never a pass and never blind. What every stage above a model
    # could have handed it rides the record as `stage_reads`. The route carries no detachment, so
    # every node reads attached.
    module Executed
      # The route's task kinds, each read as the word the lowering and the pictures use. An ask and a
      # wait are both an await_task on the route, so both read as an ask here. No compose verb places
      # a delegation (a branch never inherits `task`); it reads as the tool that places one.
      KINDS = {
        "model_task" => "model", "tool_task" => "tool", "join_task" => "join", "await_task" => "ask",
        "script_task" => "script", "delegation_task" => "task",
      }.freeze
      # The task kind each lowered step becomes: KINDS read backwards, and a `wait`, which the kernel
      # places as an await_task beside an ask.
      TASK_KINDS = KINDS.invert.merge("wait" => "await_task").freeze
      # The fields one reading's verdict carries, kept beside the other reading.
      VERDICT = %w[graph exact_edges exact_reads first_time_right silent].freeze

      # The call's placements (`nodes`, route nodes in graph order), the waits and reads between them
      # with every other node folded into the placement it hangs under, what each stage placed, and
      # the tool each tool placement called (`tools`, off the task rows: the route's nodes carry none).
      # `positional` holds, per placement, the reads that came through the kernel's `input_from` and
      # not through a name.
      Plan = Data.define(:call, :nodes, :edges, :reads, :positional, :children, :tools) do
        def empty? = nodes.empty?
        def stage?(key) = nodes.fetch(key)["kind"] == "script_task"
        def stages = nodes.keys.select { |key| stage?(key) }
        def stage_free? = stages.empty?
        def expanded?(key) = stage?(key) && children.fetch(key).any?

        # A stage that computed a value: it completed and placed nothing.
        def valued?(key) = stage?(key) && nodes.fetch(key)["status"] == "completed" && children.fetch(key).empty?

        # The values something in the plan waits on or reads: the picture contracts each one no
        # label takes, as a stage that computed nothing is contracted.
        def transparent
          stages.select { |key| valued?(key) && (edges.any? { |from, _| from == key } || reads.values.any? { |read| read.include?(key) }) }
        end

        # The stages a step hangs under, nearest first, up to the call.
        def stages_above(key)
          parent = nodes.fetch(key)["expansion_parent"]
          nodes.key?(parent) ? [parent, *stages_above(parent)] : []
        end

        # The model steps a stage placed.
        def models_of(stage) = children.fetch(stage).select { |key| nodes.fetch(key)["kind"] == "model_task" }
      end

      # What the stages fed their model steps, by the rule above: `credited` the one model a stage
      # placed and what it is credited with, `several` the models whose stage placed more than one.
      Fed = Data.define(:credited, :several)

      # The harness's reading of the kernel's plan disagrees with what the kernel did: the harness's
      # copy of the lowering, or of the splice it contracts, has drifted.
      Drifted = Class.new(StandardError)
      # A picture this reading cannot score: the route carries no detachment.
      Unreadable = Class.new(StandardError)

      module_function

      # The plan a call placed. A graph without the ownership mark holds none: nothing on it says
      # what a stage placed or which rounds are a member's own, so it is read statically. A race a
      # step names in `result_from` is read as its exits — the join's in-edge sources, what its
      # selection is drawn from, a nested race's own in its place (`Shape.race_reads`) — before
      # they are folded into their placements, as the static lowering reads it (`Shape`), so an
      # arm's tail stage that placed nothing stays transparent and no step reads a barrier.
      # `tools` names each tool task's tool by its key, as the trace's task rows do; a graph read
      # without them names none.
      def plan(graph, call, tools: {})
        placed = Gallery.marked?(graph) ? Gallery.placed_by(graph, call) : []
        nodes = placed.to_h { |node| [node["key"], node] }
        parents = Array(graph["nodes"]).to_h { |node| [node["key"], node["expansion_parent"]] }
        owner = ->(key) { placement_of(key, nodes, parents) }
        edges = Array(graph["edges"]).map { |edge| [owner.(edge["from"]), owner.(edge["to"])] }
          .select { |from, to| from && to && from != to }.uniq
        exits = race_exits(graph)
        named = nodes.to_h { |key, node| [key, Shape.race_reads(exits, Array(node["result_from"])).filter_map(&owner) - [key]] }
        given = nodes.to_h { |key, node| [key, Array(node["input_from"]).filter_map(&owner) - [key]] }
        reads = nodes.keys.to_h { |key| [key, (given.fetch(key) | named.fetch(key)).uniq] }
        positional = nodes.keys.to_h { |key| [key, (given.fetch(key) - named.fetch(key)).uniq] }
        children = nodes.values.select { |node| node["kind"] == "script_task" }.to_h do |stage|
          [stage["key"], nodes.values.select { |node| node["expansion_parent"] == stage["key"] }.map { |node| node["key"] }]
        end
        Plan.new(call: call, nodes: nodes, edges: edges, reads: reads, positional: positional, children: children,
          tools: tools.slice(*nodes.keys))
      end

      # THE READING THE EVALS RECORD for a compose call: where the kernel placed a plan for a script
      # the evaluator built, the executed reading's verdict, with the static one beside it under
      # `static`; otherwise the static verdict alone. Whether the script built, and a refusal and its
      # buckets, are always the static evaluation's: the plan has no refusal to read. On a plan with
      # no stage the two readings must be one graph, so a disagreement is the harness's own fault
      # and raises.
      def reading(objective, static, plan)
        if static["valid_first"] && !plan.empty?
          if objective.picture&.nodes&.any?(&:detached)
            raise Unreadable, "#{objective.id}'s picture detaches a step, and the route carries no detachment"
          end

          graph = lower(plan)
          agree!(static, graph, plan) if plan.stage_free?
          labels = labels(plan)
          fed = stage_fed(plan)
          static.merge(Scoring.score_graph(objective, graph, labels: labels, transparent: plan.transparent, stage_fed: fed.several),
            "reading" => "executed", "stage_reads" => relabeled(stage_reads(plan), labels),
            "stage_fed" => relabeled(fed.credited, labels), "static" => static.slice(*VERDICT))
        else
          static.merge("reading" => "static")
        end
      end

      def lower(plan)
        expanded = plan.stages.select { |stage| plan.expanded?(stage) }
        edges = expanded.reduce(plan.edges) { |waits, stage| splice(waits, stage, plan.children.fetch(stage)) }
        credited = stage_fed(plan).credited
        nodes = plan.nodes.filter_map do |key, node|
          unless expanded.include?(key)
            kind = KINDS.fetch(node["kind"])
            Shape::Node.new(key: key, kind: kind, detached: false, reads: credited.fetch(key) { reads_of(plan, key, kind) } - [key],
              race: node.dig("join", "until"), tool: plan.tools[key], positional: positional_of(plan, key, kind),
              credited: credited.fetch(key, []) - [key])
          end
        end
        Shape::Graph.new(nodes: nodes, edges: edges).contract(plan.stages.reject { |stage| expanded.include?(stage) || plan.valued?(stage) })
      end

      # What each stage could hand a model it placed only through the model's prompt: every model a
      # stage placed, and what the stages it hangs under read.
      def stage_reads(plan)
        models = plan.nodes.select { |_, node| node["kind"] == "model_task" }.keys
        models.to_h { |key| [key, handed(plan, key)] }.reject { |_, handed| handed.empty? }
      end

      # THE MODELS A STAGE FED, read off the plan (`Fed`): each model step a stage that read results
      # placed and the kernel handed nothing — credited with what its own stage read when it is the
      # one model step that stage placed, else one of `several`.
      def stage_fed(plan)
        fed = plan.nodes.filter_map do |key, node|
          stage = node["expansion_parent"]
          next unless node["kind"] == "model_task" && plan.reads.fetch(key).empty? && plan.nodes.key?(stage) && plan.stage?(stage)

          given = spliced(plan, plan.reads.fetch(stage))
          [key, given] unless given.empty?
        end
        credited, several = fed.partition { |key, _| plan.models_of(plan.nodes.fetch(key)["expansion_parent"]).one? }
        Fed.new(credited: credited.to_h, several: several.map(&:first))
      end

      # Readable names: a step the call placed by the key its script gave it (the call's prefix
      # dropped), a step a stage placed — keyed UUIDv7 by the kernel — by its stage's name, its kind
      # and its place among that stage's steps of that kind.
      def labels(plan)
        plan.nodes.reduce({}) do |named, (key, node)|
          parent = node["expansion_parent"]
          label = if parent.nil? || parent == plan.call
            key.delete_prefix("#{plan.call}-")
          else
            before = named.keys.count { |other| plan.nodes.fetch(other).values_at("expansion_parent", "kind") == [parent, node["kind"]] }
            "#{named.fetch(parent)}/#{KINDS.fetch(node["kind"])}-#{before + 1}"
          end
          named.merge(key => label)
        end
      end

      # Whether two lowerings are one graph under another naming: a bijection that keeps each step's
      # task kind and race and maps the waits and every node's reads exactly — as a set, or in the
      # order each step reads them where `ordered`.
      def same_graph?(one, other, ordered: false)
        one.nodes.size == other.nodes.size && one.edges.size == other.edges.size &&
          matched?(one, other, one.nodes, {}, ordered)
      end

      # Each race join on the route and the sources its edges come from.
      def race_exits(graph)
        joins = Array(graph["nodes"]).select { |node| node["kind"] == "join_task" }.to_set { |node| node["key"] }
        Array(graph["edges"]).select { |edge| joins.include?(edge["to"]) }
          .group_by { |edge| edge["to"] }.transform_values { |edges| edges.map { |edge| edge["from"] } }
      end

      # The member a node belongs to: itself, or the nearest placement above it by
      # `expansion_parent`; nil outside the plan (the calling round, its continuation).
      def placement_of(key, nodes, parents)
        seen = Set.new
        until key.nil? || nodes.key?(key) || seen.include?(key)
          seen << key
          key = parents[key]
        end
        nodes.key?(key) ? key : nil
      end

      # One expanded stage out of the waits: what waited into it waits into the roots it placed.
      def splice(waits, stage, children)
        into = waits.select { |_, to| to == stage }.map(&:first)
        heirs = waits.select { |from, _| from == stage }.map(&:last) & children
        raise Drifted, "#{stage} placed #{children.join(", ")} without waiting into any of them" if heirs.empty?

        (waits.reject { |from, to| from == stage || to == stage } + into.product(heirs)).uniq
      end

      # A node's reads: the kernel's for a model and a stage, what the stages above it read for a
      # tool, nothing for a join, an ask or a delegation.
      def reads_of(plan, key, kind)
        case kind
        when "model", "script" then spliced(plan, plan.reads.fetch(key))
        when "tool" then handed(plan, key)
        else []
        end
      end

      # The reads the kernel handed a model or a stage through `input_from`, not by a name; none on
      # any other node.
      def positional_of(plan, key, kind) = %w[model script].include?(kind) ? plan.positional.fetch(key) : []

      # What every stage a step hangs under read, up to the call.
      def handed(plan, key) = spliced(plan, plan.stages_above(key).flat_map { |stage| plan.reads.fetch(stage) }.uniq)

      # Reads the kernel's splice left as it records them. It points a stage's readers at the tail of
      # what the stage placed, so a read naming a stage that expanded is a splice the harness does
      # not know.
      def spliced(plan, keys)
        stage = keys.find { |key| plan.expanded?(key) }
        raise Drifted, "a step reads #{stage}, a stage that placed #{plan.children.fetch(stage).join(", ")}" if stage

        keys
      end

      def agree!(static, graph, plan)
        unless same_graph?(Shape.lower(static.fetch("steps")), graph)
          raise Drifted, "a plan with no stage reads #{Scoring.describe(graph, labels: labels(plan)).inspect[0, 400]} " \
                         "where the script lowers to #{static["graph"].inspect[0, 400]}"
        end
      end

      def relabeled(reads, labels) = reads.to_h { |key, read| [labels.fetch(key), read.map { |source| labels.fetch(source) }] }

      def matched?(one, other, left, mapping, ordered)
        if left.empty?
          one.nodes.all? do |node|
            mine = node.reads.map { |key| mapping.fetch(key) }
            theirs = other.node(mapping.fetch(node.key)).reads
            ordered ? mine == theirs : mine.sort == theirs.sort
          end
        else
          node, *rest = left
          other.nodes.any? do |candidate|
            fits?(one, other, node, candidate, mapping) &&
              matched?(one, other, rest, mapping.merge(node.key => candidate.key), ordered)
          end
        end
      end

      def fits?(one, other, node, candidate, mapping)
        signature(one, node) == signature(other, candidate) && !mapping.value?(candidate.key) &&
          mapping.all? do |key, image|
            one.edges.include?([key, node.key]) == other.edges.include?([image, candidate.key]) &&
              one.edges.include?([node.key, key]) == other.edges.include?([candidate.key, image])
          end
      end

      def signature(graph, node)
        [TASK_KINDS.fetch(node.kind), node.race, node.reads.size,
         graph.edges.count { |_, to| to == node.key }, graph.edges.count { |from, _| from == node.key }]
      end
      private_class_method :race_exits, :placement_of, :splice, :reads_of, :positional_of, :handed, :spliced, :agree!,
        :relabeled, :matched?, :fits?, :signature
    end
  end
end
