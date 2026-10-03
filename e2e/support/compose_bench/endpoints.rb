require_relative "../../../nexus/lib/nexus/compose/evaluator"
require_relative "shape"

module E2E
  module ComposeBench
    # THE MECHANISM ENDPOINTS: facts over the steps a first script built, each the thing one re-cut
    # of the compose text or one kernel line is written to move, read the same way on every arm of an
    # A/B so an arm is judged on the mechanism it targets and not only through a picture. The first
    # two read the script as written: a stage's body is a string they do not open. The last two read
    # the EXPANDED plan — a result-free stage replaced by what it places (`Shape.inline`) — and open
    # each stage's body, since what they look for is a literal a stage adds or a failure it raises;
    # the evals read the same two over every compose call of a run
    # (`Evals::Predicates.authored_labels`), one reader behind both doors. Each reads true or false
    # per script. No endpoint reads a read by position: a step reads only what it names
    # (`Nexus::Compose::Reads`), so what a script names is the analyzer's to count off the stored
    # script, one code path for every arm.
    module Endpoints
      NAMES = %w[whole_plan_wrapper ungrouped_loop authored_labels success_filter].freeze
      # One shell command's segments: what `;`, `&&`, `||` or a line break separate.
      SHELL_SEGMENTS = /;|&&|\|\||\n/
      # A segment that prints a tag of the author's own.
      ECHO = /\A(?:echo|printf)\b/
      # A stage source that fails itself on its tool's outcome.
      THROWS = /\bthrow\b/
      OUTCOME = /\b(?:status|is_error)\b/

      # One top-level step and the source line the evaluator says placed it: a leaf's line number, a
      # group's `{line, members}`.
      Placed = Data.define(:verb, :line, :step) do
        def site = [verb, line]
        def number = verb == "parallel" ? line.fetch("line") : line
      end

      module_function

      # `built` is the evaluator's result for `script`: its steps, and each placed step's line;
      # `expanded` the same steps with their result-free stages inlined.
      def read(built, script:, expanded:)
        { "whole_plan_wrapper" => whole_plan_wrapper?(built.steps),
          "ungrouped_loop" => ungrouped_loop?(built.steps, built.lines, script),
          "authored_labels" => authored_labels?(expanded),
          "success_filter" => success_filter?(expanded) }
      end

      # A WHOLE-PLAN WRAPPER: the script is one `g.script` with no `results:`, so every step hides
      # behind a result boundary a static plan did not need.
      def whole_plan_wrapper?(steps)
        steps.length == 1 && steps.first.key?("script") && Array(steps.first.dig("script", "results")).empty?
      end

      # A LOOP OF INDEPENDENT STEPS LEFT UNGROUPED: two or more turns in a row at the top level of
      # one loop body — a step, a chain such as fetch then normalise, or one holding a group, such as
      # fetch then two readers of it at once — where some call site of the
      # body placed more leaves than its line's text calls that verb: one call site that ran more
      # than once, a `.map`, `forEach` or `for`, or a helper called in turn; and at least one turn
      # follows the one before it without naming any of its steps in `after:` or `results:`.
      # Written order chains the turns, so what the loop built to run at once runs one after
      # another. Steps written one call each, on their own lines or on one, are the author's order;
      # a loop whose handles are then grouped places a `g.parallel`, never a row of leaves; a loop
      # whose every turn chains to the one before by `after:` wrote that order on purpose. The
      # evaluator's `lines` are the author's own line numbers, counted by the line breaks V8 counts.
      def ungrouped_loop?(steps, lines, script)
        texts = script.to_s.split(Nexus::Compose::Evaluator::LINE_BREAK, -1)
        sites = placed(steps, lines)
        sites.each_index.any? do |start|
          (1..(sites.length - start) / 2).any? { |period| loop_at?(sites.drop(start), period, texts) }
        end
      end

      def placed(steps, lines)
        steps.zip(lines).map do |step, line|
          verb = (step.keys & Shape::VERBS).first
          Placed.new(verb: verb, line: line, step: step)
        end
      end

      # The loop's body is its first `period` top-level steps; its turns are the slices from there
      # that repeat the body's call sites.
      def loop_at?(sites, period, texts)
        body = sites.first(period)
        return false if body.any? { |site| site.line.nil? }

        turns = sites.each_slice(period).take_while { |turn| turn.map(&:site) == body.map(&:site) }
        turns.length > 1 && body.any? { |site| calls(texts, site) < turns.length } && independent_turn?(turns)
      end

      # A turn that names none of the previous turn's leaves runs after it only because it was
      # written after it. Names inside one turn (`results: [fetch]`) are the turn's own chain.
      def independent_turn?(turns)
        turns.each_cons(2).any? do |before, turn|
          keys = leaves(before.map(&:step)).map { |_verb, body| body.fetch("key") }
          !leaves(turn.map(&:step)).flat_map { |_verb, body| [*body["after"], *body["results"]] }.intersect?(keys)
        end
      end

      # How many times the placing line's text calls the verb.
      def calls(texts, site)
        texts.fetch(site.number - 1, "").scan(/\.\s*#{site.verb}\s*\(/).length
      end

      # LABELS OF THE AUTHOR'S OWN, telling a group's results apart — the work the envelope's
      # `<call>` line does for a tool result. True when some group of two or more members carries
      # either kind. An ECHO TAG: two or more members' tools run a command of more than one shell
      # segment, one of which echoes or prints words that differ between the members
      # (`bin/probe alpha && echo HOST=alpha`). A TAG CHAIN: every member ends on a stage that reads
      # its own tool alone, and the stages' source or `params` differ between the members — the
      # literal each adds (`return {host: "alpha", output: r.output}`); a stage every member shares
      # byte for byte adds none. A table of names a later stage reads by position is that stage's
      # order, never a label.
      def authored_labels?(steps)
        tools = tools_of(steps)
        groups(steps).any? { |members, _race| echo_tagged?(members, tools) || tag_chained?(members, tools) }
      end

      # A RACE WHOSE MEMBERS FILTER THEIR OWN SUCCESS: every member of a racing group (`until` "any" or
      # a count) ends on a stage that reads its own tool alone and throws on its status or `is_error`.
      # The kernel counts a call that completed as a success whatever its `is_error` says, so a
      # member that must not win fails itself; `<call>` names a result and cannot stand in for that,
      # which is why this is a fact beside the labels and never one of them.
      def success_filter?(steps)
        tools = tools_of(steps)
        groups(steps).any? do |members, race|
          race && members.all? { |member| (stage = own_stage(member, tools)) && filters?(stage) }
        end
      end

      def echo_tagged?(members, tools)
        tags = members.map { |member| echo_tags(member_tool(member, tools)) }.reject(&:empty?)
        tags.length > 1 && tags.uniq.length > 1
      end

      def tag_chained?(members, tools)
        stages = members.map { |member| own_stage(member, tools) }
        return false if stages.include?(nil)

        stages.map { |stage| stage.fetch("results") }.uniq.length == stages.length &&
          stages.map { |stage| stage.values_at("script", "params") }.uniq.length > 1
      end

      # The segments of a tool's command that print a tag, when the command has more than one.
      def echo_tags(tool)
        segments = tool.to_h.dig("input", "command").to_s.split(SHELL_SEGMENTS).map(&:strip).reject(&:empty?)
        segments.length > 1 ? segments.grep(ECHO) : []
      end

      # The member's first tool, or the one tool its closing stage reads.
      def member_tool(member, tools)
        leaves = plan_leaves([member])
        tool = leaves.find { |verb, _body| verb == "tool" }
        tool ? tool.last : tools[own_stage(member, tools)&.fetch("results")&.first]
      end

      # The stage a member ends on when that stage reads exactly one tool; nil otherwise.
      def own_stage(member, tools)
        verb, body = plan_leaves([member]).last
        read = Array(body["results"]) if verb == "script"
        body if read&.length == 1 && tools.key?(read.first)
      end

      def filters?(stage) = stage.fetch("script").to_s.match?(THROWS) && stage.fetch("script").to_s.match?(OUTCOME)

      # Every tool leaf of the plan by key, an expansion's included.
      def tools_of(steps) = plan_leaves(steps).select { |verb, _body| verb == "tool" }.to_h { |_verb, body| [body.fetch("key"), body] }

      # Every group of two or more members in the plan, an expansion's and a member's included, with
      # whether it races: `until` names "any" or a count.
      def groups(steps)
        Array(steps).flat_map do |step|
          sequence = Array.try_convert(step)
          if sequence
            groups(sequence)
          elsif step.key?("parallel")
            members = step["parallel"]
            own = members.length > 1 ? [[members, ![nil, "all"].include?(step["until"])]] : []
            own + members.flat_map { |member| groups([member]) }
          elsif step.key?(Shape::EXPANSION)
            groups(step.dig(Shape::EXPANSION, "steps"))
          else
            []
          end
        end
      end

      # Every leaf under `steps` as [verb, body], in written order, an expansion opened into its steps:
      # the expanded plan's own walk, which the evals' readers of a composed brief share.
      def plan_leaves(steps)
        leaves(steps).flat_map { |verb, body| verb == Shape::EXPANSION ? plan_leaves(body.fetch("steps")) : [[verb, body]] }
      end

      # Every leaf under `steps` as [verb, body], in written order: `Shape.map_leaves`' own walk.
      def leaves(steps)
        found = []
        Shape.map_leaves(steps) { |verb, body| found << [verb, body] }
        found
      end
      private_class_method :placed, :loop_at?, :independent_turn?, :calls, :echo_tagged?, :tag_chained?, :echo_tags,
        :member_tool, :own_stage, :filters?, :tools_of, :groups, :leaves
    end
  end
end
