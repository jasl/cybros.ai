require_relative "drawing"
require_relative "executed"
require_relative "inline"
require_relative "scoring"
require_relative "shape"
require_relative "worlds"

module E2E
  module ComposeBench
    # THE REHEARSED READING of a script the evaluator built: the plan the kernel would place, run in
    # the objective's declared world (`Worlds`), drawn in the route's shape (`Drawing`) and scored by
    # the tree's own executed reading. A stage that reads results runs through the kernel's evaluator
    # over the envelopes its `results:` would carry, and what it does becomes the plan; a draw with no
    # such stage rehearses trivially — one reader for every draw. The script's text is read as the
    # other readings read it (`Scoring`, `Probe`); this reading only adds its own record key.
    #
    # A draw runs in W0 first, then in every world over the dimensions W0's calls reached. Two credit
    # policies read each world: the tree's own (`Executed.reading`, whose stage-fed credit — where the
    # tree has one — hands a model a stage placed what its stage read) and the uncredited one, the same
    # plan with that credit taken back, which decides. The record's `first_time_right` is right in
    # every world, uncredited; `credited_first_time_right` the same under the tree's own policy;
    # `liberal` right in some world; `world_dependent` where the worlds disagree.
    module Rehearsal
      # The verdict fields of W0's own reading, shown as the tree reads them.
      SHOWN = %w[graph exact_edges exact_reads silent stage_reads stage_fed].freeze
      # Every key the record's `rehearsed` may carry (`stage_fed` only where the tree credits one).
      KEYS = [*SHOWN, "first_time_right", "credited_first_time_right", "liberal", "worlds", "touched", "world_dependent",
              "stages", "unknown_commands", "failed_on_model_output", "edited", "dropped_value_on_race_member"].freeze
      # One world's rehearsal: the plan inlined with the world, the run that settled it, the drawing,
      # the plan it reads as, the tree's own reading, and the uncredited verdict.
      Rehearsed = Data.define(:inlined, :run, :drawing, :plan, :read, :uncredited) do
        def right? = uncredited["first_time_right"] == true
        def credited_right? = read["first_time_right"] == true
      end

      module_function

      # The record's `rehearsed` hash for a valid first script.
      def reading(objective, built, scored, tool_names:)
        first = rehearse(objective, built, scored, tool_names: tool_names, variant: Worlds::W0)
        worlds = [first, *Worlds.variants(first.run.touched).map do |variant|
          rehearse(objective, built, scored, tool_names: tool_names, variant: variant)
        end]
        rights = worlds.map(&:right?)
        { **first.read.slice(*SHOWN),
          "first_time_right" => rights.all?, "credited_first_time_right" => worlds.all?(&:credited_right?),
          "liberal" => rights.any?, "worlds" => worlds.length, "touched" => first.run.dimensions,
          "world_dependent" => rights.uniq.length > 1, "stages" => first.run.stages, "unknown_commands" => first.run.unknown,
          "failed_on_model_output" => first.run.model_failures, "edited" => first.run.edited,
          "dropped_value_on_race_member" => dropped_values(first.plan) }
      end

      # One world's rehearsal. A race whose ranked winner failed is rehearsed again with that exit
      # excluded, so the race goes to the next finisher, until every race's winners stand.
      def rehearse(objective, built, scored, tool_names:, variant:, excluded: {})
        inlined, run = Worlds::Run.open(world: Worlds.for(objective), variant: variant, tool_names: tool_names, excluded: excluded) do |opened|
          [Shape.inline(built.steps, tool_names: tool_names, world: opened), opened]
        end
        failing = run.failed_winners
        if failing.empty?
          drawing = Drawing.draw(inlined, run)
          plan = Executed.plan(drawing.graph, Drawing::CALL, tools: drawing.tools)
          read = Executed.reading(objective, scored, plan)
          Rehearsed.new(inlined: inlined, run: run, drawing: drawing, plan: plan, read: read, uncredited: uncredited(objective, plan, read))
        else
          rehearse(objective, built, scored, tool_names: tool_names, variant: variant,
            excluded: excluded.merge(failing) { |_, known, more| known | more })
        end
      end

      # THE UNCREDITED VERDICT, one rule both trees can apply: the plan lowered as the tree lowers it,
      # each model the tree's reading credited (`stage_fed`, by label) reading nothing — the credit's
      # own condition is that the kernel handed that model nothing — scored against the picture.
      # Where the tree credits nothing it is the tree's own verdict.
      def uncredited(objective, plan, read)
        if read["reading"] == "executed"
          labels = Executed.labels(plan)
          credited = read.fetch("stage_fed", {}).keys.map { |label| labels.key(label) }
          lowered = Executed.lower(plan)
          stripped = lowered.with(nodes: lowered.nodes.map { |node| credited.include?(node.key) ? node.with(reads: []) : node })
          Scoring.score_graph(objective, stripped, labels: labels, transparent: plan.transparent)
        else
          read.slice(*Executed::VERDICT)
        end
      end

      # The value stages nothing waits on that wait directly on a race member — a closing value the
      # picture drops as the plan's answer although it names one probe; counted, never scored here.
      def dropped_values(plan)
        graph = Executed.lower(plan)
        joins = graph.nodes.select { |node| node.kind == "join" }.map(&:key)
        members = graph.edges.filter_map { |from, to| from if joins.include?(to) }
        plan.stages.count do |stage|
          plan.valued?(stage) && graph.edges.none? { |from, _| from == stage } &&
            graph.edges.any? { |from, to| to == stage && members.include?(from) }
        end
      end
      private_class_method :uncredited, :dropped_values
    end
  end
end
