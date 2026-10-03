require_relative "shapes"

module E2E
  module Gallery
    # THE THREAD A GRAPH ENCODES — derived from the graph route's EDGES and the kernel's `spine`
    # mark, which is a DIFFERENT derivation from the kernel's own (keys, the mark, and the round's
    # reading-list column), so a journey's `assert_equal` between the two is a real check and not
    # the same arithmetic twice:
    #
    # - the SPINE: the visible model nodes marked `spine: true`, in
    #   authoring order;
    # - a round's CALLS: the visible tool nodes a model node fanned (an
    #   in-edge from a model node) that feed that spine round (a structural
    #   out-edge into it) — the READER, never the maker; a summarizer hung
    #   under a round (`k1 → rN`, no maker) and an `--until` check (placed
    #   before a hold; the next round only NAMES it, a `structural: false`
    #   edge) are not calls;
    # - a call's ROOTS: its out-edges into VISIBLE nodes that are not spine
    #   rounds — an ask's or a spawn's await is hidden, so neither opens a
    #   branch; a `task` call's `-model-1` and a compose's members do;
    # - a branch's ROUNDS: the visible, spine-false model nodes reachable
    #   along out-edges from the roots, crossing anything (a hidden join, a
    #   hidden round) but STOPPING at a spine-marked node and never
    #   crossing it — so on fan_join the walk ends at the reader and the
    #   merge is under the prefix, never over-counted.
    #
    # A model node without the mark is a wrong drawing and is refused.
    # Pure Ruby: the paper test runs it on the nine hand-drawn shapes.
    module Fold
      module_function

      def thread_of(graph)
        nodes = Array(graph["nodes"])
        nodes.each do |node|
          next unless node["kind"] == "model_task"

          raise ArgumentError, "model node #{node["key"]} carries no spine mark" unless node.key?("spine")
        end
        by_key = nodes.to_h { |node| [node["key"], node] }
        visible = nodes.reject { |node| hidden?(node) }

        rows = visible.select { |node| spine_round?(node) }.map do |round|
          calls = visible.select { |node| node["kind"] == "tool_task" && fanned_into?(graph, by_key, node["key"], round["key"]) }
          {
            "key" => round["key"],
            "calls" => calls.map { |call| call["key"] },
            "branches" => calls.select { |call| roots_of(graph, by_key, call["key"]).any? }.map { |call| call["key"] },
          }
        end
        branches = rows.flat_map { |row| row["branches"] }.to_h do |call|
          [call, rounds_under(graph, by_key, call)]
        end
        { "spine" => rows, "branches" => branches }
      end

      def hidden?(node) = node["visibility"] == "hidden"
      def spine_round?(node) = node["kind"] == "model_task" && node["spine"] == true

      # A named read or an `after:` wait is drawn `structural: false` and feeds no round: only
      # placement does. A drawing without the flag draws placement.
      def fanned_into?(graph, by_key, tool, round)
        Array(graph["edges"]).any? { |edge| edge["from"] == tool && edge["to"] == round && edge["structural"] != false } &&
          Gallery.edges_into(graph, tool).any? { |key| by_key.dig(key, "kind") == "model_task" }
      end

      def roots_of(graph, by_key, call)
        Gallery.edges_out_of(graph, call).select do |key|
          node = by_key[key]
          node && !hidden?(node) && !spine_round?(node)
        end
      end

      def rounds_under(graph, by_key, call)
        seen = {}
        frontier = roots_of(graph, by_key, call)
        until frontier.empty?
          key = frontier.shift
          next if seen[key]

          node = by_key[key]
          next if node.nil? || spine_round?(node)

          seen[key] = true
          frontier.concat(Gallery.edges_out_of(graph, key))
        end
        Array(graph["nodes"])
          .select { |node| seen[node["key"]] && node["kind"] == "model_task" && !hidden?(node) }
          .map { |node| node["key"] }
      end
    end

    def self.thread_of(graph) = Fold.thread_of(graph)
  end
end
