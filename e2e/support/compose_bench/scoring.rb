require_relative "../../../nexus/lib/nexus/compose/evaluator"
require_relative "buckets"
require_relative "inline"
require_relative "shape"

module E2E
  module ComposeBench
    # ONE SCRIPT, SCORED: through the SHIPPED evaluator, then the harness's lowering — written
    # order for the waits, `Nexus::Compose::Reads` for the reads — against the objective's picture
    # (`score`); and ONE GRAPH against a picture, whichever reading
    # lowered it (`score_graph`). The text bench scores what a direct provider call wrote on its
    # text alone. The evals read the same bytes off a rho turn's trace (the compose row's
    # `tool_input.script`) and score them here too, but where the trace holds the plan the kernel
    # placed for the script they score that plan (`Executed`) and keep this text reading beside it,
    # still the only word on whether the script built. So a script whose stages place steps at run
    # time reads differently on the two benches: their cells share columns, never a measure, and the
    # runs ledger says they are not comparable.
    #
    # `tool_names` is the set the round declared: the probe's harness tools, the evals' declared set
    # (the sealed request's, else the style's) — what the kernel refuses after the evaluator built
    # the steps, `Compose::Lower` (a tool outside it, a graph verb in a `g.model`'s `tools`, an
    # over-long key) and then the step compiler (a key out of format, a value the row store cannot
    # hold, the batch's bounds), is read in the kernel's own sentence (`Shape.lowering_refusal`).
    module Scoring
      module_function

      def score(objective, script:, params:, tool_names:)
        score_built(objective, Nexus::Compose::Evaluator.call(script: script, params: params || {}, tool_names: tool_names),
          tool_names: tool_names)
      end

      # The verdict over the evaluator's result for the script, for a caller that keeps that result
      # for readings of its own.
      def score_built(objective, built, tool_names:)
        unless built.built?
          return { "valid_first" => false, "first_time_right" => false,
                   "refusal" => built.refusal.to_s, "detail" => built.detail.to_s[0, 400],
                   "loud" => Buckets.loud(built.refusal, built.detail),
                   "group" => Buckets.normalize(built.detail) }
        end

        lowering = Shape.lowering_refusal(built.steps, tool_names)
        return score_lowering_refusal(lowering) if lowering

        inlined = Shape.inline(built.steps, tool_names: tool_names)
        { "valid_first" => true, "steps" => built.steps,
          **score_graph(objective, Shape.lower(built.steps), placers: inlined.placers, refused: inlined.refused.map(&:key)),
          "compose_zero" => false }
      end

      # ONE GRAPH AGAINST THE OBJECTIVE'S PICTURE, whichever reading lowered it — the script's text
      # (`score`) or the plan the kernel placed (`Executed`). `labels` names the graph's keys where
      # they are not the script's own. `placers` names the stages of the script's text that place
      # steps (`Inlined#placers`) and `refused` the ones the kernel fails (`Inlined#refused`); the
      # plan that ran holds neither — a stage that placed steps is contracted into them, and one that
      # failed is transparent. `transparent` names the value stages of the plan that ran that
      # something consumes (`Executed::Plan#transparent`): the text cannot know that a stage which
      # reads results placed nothing, so its reading names none; `stage_fed` the model steps of the
      # plan that ran a stage fed with values the graph cannot attribute (`Executed.stage_fed`),
      # which no text reading can see either. The picture reads the graph with no
      # wait out of a launch (`Shape::LAUNCHES`) — a step after one is read as waiting on the launch,
      # never on what it launched — while the record shows every wait; each reading lowers the whole
      # graph first, so the executed reading's agreement with the static one is checked on the waits
      # as written.
      def score_graph(objective, graph, labels: {}, placers: [], refused: [], transparent: [], stage_fed: [])
        shape = objective.control? ? { "exact_edges" => false, "exact_reads" => false, "silent" => ["over_reach"] } :
          objective.picture.score(graph.without_launch_waits, placers: placers, refused: refused, transparent: transparent,
            stage_fed: stage_fed)
        { "graph" => describe(graph, labels: labels), "exact_edges" => shape["exact_edges"], "exact_reads" => shape["exact_reads"],
          "first_time_right" => shape["exact_edges"] && shape["exact_reads"], "silent" => shape["silent"] }
      end

      # A refusal the kernel's lowering or step compiler makes and the
      # evaluator cannot, in the sentence `Shape.lowering_refusal` spells.
      def score_lowering_refusal(lowering)
        { "valid_first" => false, "first_time_right" => false, "refusal" => lowering.refusal,
          "detail" => lowering.detail, "loud" => Buckets.loud(lowering.refusal, lowering.detail),
          "group" => Buckets.normalize(lowering.detail) }
      end

      # The graph as the record carries it. Its reads are every node's the picture can compare: a
      # foreground model's, and any other node's the lowering gave reads — a stage's `results:`, a
      # tool a stage decided on what it read. It shows every step that ran; a `script` node the plan
      # kept that no label takes was set apart before the comparison (`Picture`): contracted where
      # something consumes it (transparent), dropped as the plan's answer where nothing does and the
      # picture has no tail.
      def describe(graph, labels: {})
        name = ->(key) { labels.fetch(key, key) }
        { "nodes" => graph.nodes.map { |n| [name.(n.key), n.kind, n.detached ? "background" : nil, n.race].compact.join(":") },
          "edges" => graph.edges.map { |from, to| "#{name.(from)}->#{name.(to)}" },
          "reads" => graph.nodes.select { |node| node.foreground_model? || node.reads.any? }
            .to_h { |node| [name.(node.key), node.reads.map(&name)] } }
      end
    end
  end
end
