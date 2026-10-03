require_relative "../../../nexus/lib/nexus/compose/evaluator"
require_relative "../compose_bench/executed"
require_relative "../compose_bench/inline"

module E2E
  module Evals
    # THE FLOOR'S COMPOSE BAR, USABLE GENERATION, read on one compose call of a `Trace` over the graph
    # the kernel RAN and never against the objective's picture: the kernel settled the call without
    # an error; it placed at least one node (`Trace#under`, the one membership walk); every stage
    # source parses; and at least one placed node stands — one that is not a stage that failed on its
    # own script. A stage that failed on the data it read counts against the bar as one that failed on
    # its own script does, so it is forgiven only while another placed node stands; a tool or model
    # step that failed at run time is itself a node that stands, its failure the run's and never the
    # generation's. A stage that expanded stands for nothing — the kernel's splice hands its place to
    # what it placed — and neither does a race's join, the kernel's barrier over its members, which
    # holds no work of its own.
    #
    # The route serves no stage's definition, so the parse is read twice. Statically, through the text
    # bench's inliner (`Shape.inline`): every stage the script carries, and every stage a result-free
    # stage places (its source is known before the run), runs as the kernel's stage run will, with no
    # results, and only `script_syntax_error` counts — a failure on the empty list is the list's. And
    # from the kernel: a stage the call placed that failed with that word, which reaches the stages a
    # result-reading stage placed, whose source no text can know. The text bench's `usable` reads this
    # bar without a run: what a result-reading stage does with real output only this bar sees.
    module Usable
      module_function

      # `true`, or a String in the trace's own words. `tool_names`: the set the calling round declared,
      # the set the kernel built the script under.
      def call(trace, row, tool_names:)
        key = row["key"]
        return "the compose call #{key} #{row["status"]}: #{row.dig("error", "key").inspect}" unless row["status"] == "completed"
        # The kernel settles a refused script `completed`, its result the refusal.
        return "the kernel refused the compose call #{key}: its result is an error" if Hash(row["result"])["is_error"]

        placed = trace.under(key)
        return "the compose call #{key} placed nothing" if placed.empty?

        unparsed = unparsed_in_the_script(trace.input_of(row), key, tool_names) + unparsed_by_the_kernel(key, placed)
        return unparsed.first unless unparsed.empty?
        return "nothing #{key} placed stands: the stages that did its work failed on their own scripts: " \
               "#{placed.select { |node| failed_stage?(node) }.map { |node| failure(node) }.join(", ")}" if standing(placed).empty?

        true
      end

      # A plan the kernel placed for a script the harness's evaluator refuses is the harness's own
      # fault, never the model's: it raises, and the lane files a raised predicate as a lane bug.
      def unparsed_in_the_script(input, key, tool_names)
        built = Nexus::Compose::Evaluator.call(script: input["script"].to_s, params: Hash.try_convert(input["params"]) || {},
          tool_names: tool_names)
        unless built.built?
          raise ComposeBench::Executed::Drifted,
            "the kernel placed #{key}'s plan and the harness refused its script #{built.refusal}: #{built.detail.to_s[0, 200]}"
        end

        ComposeBench::Shape.inline(built.steps, tool_names: tool_names).unparsed
          .map { |stage| "stage #{stage.key} of #{key} does not parse: #{stage.detail[0, 200]}" }
      end

      def unparsed_by_the_kernel(key, placed)
        placed.select { |node| failed_stage?(node) && node["error_key"] == ComposeBench::Shape::SYNTAX_ERROR }
          .map { |node| "stage #{node["key"]} under #{key} does not parse: the kernel failed it #{node["error_key"]}" }
      end

      def standing(placed)
        parents = placed.map { |node| node["expansion_parent"] }
        placed.reject do |node|
          failed_stage?(node) || node["kind"] == "join_task" || (node["kind"] == "script_task" && parents.include?(node["key"]))
        end
      end

      def failed_stage?(node) = node["kind"] == "script_task" && node["status"] == "failed"

      def failure(node) = "#{node["key"]}(#{node["status"]} #{node["error_key"]})"
    end
  end
end
