require "set"
require_relative "executed"
require_relative "shape"

module E2E
  module ComposeBench
    module Rehearsal
      # THE PLAN THE KERNEL WOULD PLACE, drawn in the graph route's shape so the executed reading
      # (`Executed.plan`, `Executed.reading`) scores it exactly as it scores a captured one. The steps
      # are the tree's own lowering of the rehearsed plan with every expansion in place (`Shape.lower`):
      # the roots of what a stage placed wait on what the stage waited on, and its readers on its final
      # leaf — the tree's pinned copy of the kernel's splice. Each stage that expanded is then put back
      # as the route shows it, a `script_task` ahead of what it placed: what waited into its roots
      # waits into it, and it into its roots, so `Executed.splice` takes it out again and restores the
      # lowering, and no read ever names it. Every node carries the ownership mark — its stage, or the
      # call — and its status off the run: a leaf's envelope, a stage's outcome (an expansion
      # completed), a join's race, and `waiting` for everything downstream of a stage the wall cut.
      # A node's reads are the kernel's two: `result_from` its own `results:`, `input_from` what the
      # lowering hands it beside them (none where the tree's reads are named ones).
      module Drawing
        CALL = Shape::CALL_KEY
        Drawn = Data.define(:graph, :tools)

        module_function

        def draw(inlined, run)
          lowered = Shape.lower(inlined.steps)
          bodies = bodies(inlined.steps)
          edges = inlined.inlined.reduce(lowered.edges) { |waits, stage| inserted(waits, stage, lowered.keys) }
          waiting = downstream(edges, run.cut)
          exits = race_exits(lowered)
          nodes = ordered(lowered.keys, inlined.inlined).map do |key|
            node(key, lowered.node(key), bodies[key], exits, status: waiting.include?(key) ? "waiting" : status(key, run, inlined))
          end
          tools = bodies.filter_map { |key, (verb, body)| [key, body.fetch("name")] if verb == "tool" }.to_h
          Drawn.new(graph: { "nodes" => nodes, "edges" => edges.map { |from, to| { "from" => from, "to" => to } } }, tools: tools)
        end

        # Every step of the plan by key, a stage's expansion among them with the steps it holds.
        def bodies(steps)
          found = {}
          Shape.map_leaves(steps) do |verb, body|
            found[body.fetch("key")] = [verb, body]
            found.merge!(bodies(body.fetch("steps"))) if verb == Shape::EXPANSION
            { verb => body }
          end
          found
        end

        # One expanded stage put back between what waited into its roots — the steps it placed that
        # wait on none of its own — and the roots themselves.
        def inserted(edges, stage, keys)
          inside = ->(key) { key.start_with?("#{stage}/") }
          roots = keys.select { |key| inside.(key) && edges.none? { |from, to| to == key && inside.(from) } }
          entering = edges.select { |from, to| roots.include?(to) && !inside.(from) }
          edges - entering + entering.map(&:first).uniq.map { |from| [from, stage] } + roots.map { |root| [stage, root] }
        end

        def downstream(edges, from)
          reached = Set.new(from)
          frontier = from
          until frontier.empty?
            frontier = edges.filter_map { |source, target| target if frontier.include?(source) && !reached.include?(target) }.uniq
            reached.merge(frontier)
          end
          reached
        end

        # Each race's join and the exits it waits on, as a read of the race is read (`Shape.race_reads`).
        def race_exits(graph)
          joins = graph.nodes.select { |node| node.kind == "join" }.map(&:key)
          joins.to_h { |join| [join, graph.edges.filter_map { |from, to| from if to == join }] }
        end

        # The route's order: a stage ahead of everything it placed, the outer stage first.
        def ordered(keys, stages)
          keys.each_with_object([]) do |key, order|
            order.concat(stages.select { |stage| key.start_with?("#{stage}/") && !order.include?(stage) })
            order << key
          end
        end

        def status(key, run, inlined) = inlined.inlined.include?(key) ? "completed" : run.status(key)

        def node(key, lowered, found, exits, status:)
          verb, body = found || ["join", {}]
          results = Array(body["results"])
          if verb == Shape::EXPANSION
            kind = "script"
            given = []
            race = nil
          else
            kind = lowered.kind
            given = lowered.reads - Shape.race_reads(exits, results)
            race = lowered.race
          end
          { "key" => key, "kind" => Executed::TASK_KINDS.fetch(kind), "status" => status,
            "expansion_parent" => key.include?("/") ? key[0...key.rindex("/")] : CALL,
            "result_from" => results, "input_from" => given, "join" => (race && { "until" => race }) }.compact
        end
        private_class_method :bodies, :inserted, :downstream, :race_exits, :ordered, :status, :node
      end
    end
  end
end
