module AgentAPI
  # Current execution structure, material sources and generation ownership,
  # all named by task keys. Mermaid draws only scheduling dependencies.
  # Read-only by construction: the graph is authored only through tasks.
  module AgentLoopGraphPresenter
    Node = Data.define(:key, :kind, :lifetime, :wake, :status, :visibility, :deliverable,
      :input_from, :result_from, :spine, :error_key, :join, :expansion_parent) do
      def to_h = super.compact
    end

    Edge = Data.define(:from, :to, :structural)

    Graph = Data.define(:nodes, :edges) do
      def mermaid = AgentLoopGraphPresenter.mermaid(self)

      def to_h = { nodes: nodes.map(&:to_h), edges: edges.map(&:to_h), mermaid: mermaid }
    end

    # A label is quoted Mermaid text; anything outside this set is drawn as
    # `_` so a node's words can never close the quote or draw an edge.
    LABEL_CHARACTERS = %r{[^\w .,:()=/·-]}

    class << self
      def call(agent_loop)
        nodes = agent_loop.agent_loop_nodes.includes(:incoming_edges).order(:created_at, :id).to_a
        build(nodes: nodes, deliverable_node_id: agent_loop.deliverable_node_id)
      end

      # Pure over loaded rows (or doubles shaped like them), so the contract
      # generator renders the same projection the route serves.
      def build(nodes:, deliverable_node_id:)
        keys = nodes.to_h { |node| [node.id, node.node_key] }
        Graph.new(
          nodes: nodes.map do |node|
            node_projection(node, deliverable: node.id == deliverable_node_id,
              expansion_parent: keys[node.expansion_parent_id])
          end,
          edges: nodes.flat_map do |node|
            node.incoming_edges.sort_by(&:from_node_id).filter_map do |edge|
              # Expansion can commit between the two reads. A later refresh
              # includes its new nodes; this picture keeps its endpoints closed.
              source = keys[edge.from_node_id]
              Edge.new(from: source, to: node.node_key, structural: edge.structural) if source
            end
          end
        )
      end

      # Positional ids: `a-b` and `a_b` are two keys and must stay two nodes.
      # The status rides as a class for a renderer to style; the deliverable
      # draws in the subroutine shape.
      def mermaid(graph)
        ids = graph.nodes.each_with_index.to_h { |node, index| [node.key, "n#{index}"] }
        lines = ["flowchart TD"]
        graph.nodes.each do |node|
          open, close = node.deliverable ? ["[[", "]]"] : ["[", "]"]
          lines << "  #{ids.fetch(node.key)}#{open}\"#{label(node)}\"#{close}:::#{node.status}"
        end
        graph.edges.each do |edge|
          lines << "  #{ids.fetch(edge.from)} --> #{ids.fetch(edge.to)}"
        end
        lines.join("\n")
      end

      private

        def node_projection(node, deliverable:, expansion_parent:)
          Node.new(
            key: node.node_key,
            kind: node.task_kind,
            lifetime: node.lifetime,
            wake: node.wake,
            status: AgentLoopPresenter.public_status(node.status),
            visibility: node.transcript_visibility,
            deliverable: deliverable,
            input_from: node.input_from_node_keys || [],
            result_from: node.result_from_node_keys || [],
            spine: spine_projection(node),
            error_key: node.error_key.presence,
            join: join_projection(node),
            expansion_parent: expansion_parent
          )
        end

        # THE KERNEL'S OWN MARK, never inferred from a key: a compose
        # member's continuations and a summarizer's `kN`
        # are keyed like rounds, and a reader that took `r<N>` for the
        # conversation's thread counted them as it. One predicate, shared
        # with `AgentLoop#spine_nodes`:
        # a round whose mark is not `branch` is the spine — `r1`'s mark
        # is NULL and counts. Nil on every other kind; `compact` drops it.
        def spine_projection(node)
          return nil unless node.task_kind == "model_task"

          node.continuation_source != AgentLoops::Tasks::Compile::BRANCH
        end

        # A race reads back in the words that wrote it — `until` and `losers`
        # — never the columns behind them; an `all` fan places no row.
        def join_projection(node)
          return nil if node.join_mode.nil?

          {
            until: node.join_mode == "quorum" ? node.quorum_k : node.join_mode,
            losers: node.loser_policy == "cancel_losers" ? "cancel" : "run_out",
          }
        end

        def label(node)
          parts = ["#{node.key} · #{node.kind}#{join_terms(node)}", node.status, node.error_key]
          parts.compact.join(" · ").gsub(LABEL_CHARACTERS, "_")
        end

        def join_terms(node)
          return "" if node.join.nil?

          " (#{node.join[:until]}, #{node.join[:losers]})"
        end
    end
  end
end
