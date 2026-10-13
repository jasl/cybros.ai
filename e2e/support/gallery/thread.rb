require_relative "shapes"

module E2E
  module Gallery
    # Tool continuations own opaque-keyed work without a scheduling edge from the owner.
    # Combine that ownership with execution edges when deriving the visible branch tree.
    module Fold
      module_function

      def thread_of(graph)
        nodes = Array(graph["nodes"])
        nodes.each do |node|
          next unless node["kind"] == "model_task"

          raise ArgumentError, "model node #{node["key"]} carries no mainline mark" unless node.key?("mainline")
        end
        by_key = nodes.to_h { |node| [node["key"], node] }
        visible = nodes.reject { |node| hidden?(node) }

        rows = visible.select { |node| mainline_model_task?(node) }.map do |round|
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
        { "mainline" => rows, "branches" => branches }
      end

      def hidden?(node) = node["visibility"] == "hidden"
      def mainline_model_task?(node) = node["kind"] == "model_task" && node["mainline"] == true

      # A named read or an `after:` wait is drawn `structural: false` and feeds no round: only
      # placement does. A drawing without the flag draws placement.
      def fanned_into?(graph, by_key, tool, round)
        Array(graph["edges"]).any? { |edge| edge["from"] == tool && edge["to"] == round && edge["structural"] != false } &&
          Gallery.edges_into(graph, tool).any? { |key| by_key.dig(key, "kind") == "model_task" }
      end

      def roots_of(graph, by_key, call)
        (Gallery.edges_out_of(graph, call) + owned_children(by_key, call)).uniq.select do |key|
          node = by_key[key]
          node && !hidden?(node) && !mainline_model_task?(node)
        end
      end

      def owned_children(by_key, key)
        by_key.values.select { |node| node["expansion_parent"] == key && !hidden?(node) }.map { |node| node["key"] }
      end

      def rounds_under(graph, by_key, call)
        seen = {}
        frontier = roots_of(graph, by_key, call)
        until frontier.empty?
          key = frontier.shift
          next if seen[key]

          node = by_key[key]
          next if node.nil? || mainline_model_task?(node)

          seen[key] = true
          frontier.concat(Gallery.edges_out_of(graph, key) + owned_children(by_key, key))
        end
        Array(graph["nodes"])
          .select { |node| seen[node["key"]] && node["kind"] == "model_task" && !hidden?(node) }
          .map { |node| node["key"] }
      end
    end

    def self.thread_of(graph) = Fold.thread_of(graph)
  end
end
