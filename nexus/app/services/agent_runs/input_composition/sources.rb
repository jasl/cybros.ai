module AgentRuns
  class InputComposition
    # The rows a reader continues from, in its read order. No `input_from`
    # crosses a race — a race reaches a reader only by name, as what it
    # selected (`TaskResultProjection.referenced`) — so there is nothing to
    # filter; what a reader lost is a round refused before it minted.
    class Sources
      def initialize(node, sources: nil)
        @node = node
        @sources = sources
      end

      def call = recover_unstarted_sources(@sources || load_sources(@node.input_from_node_keys))

      private

        def load_sources(keys)
          keys = Array(keys)
          rows = @node.agent_run.agent_run_tasks.where(node_key: keys).index_by(&:node_key)
          keys.map { |key| rows[key] || raise(MissingSource) }
        end

        # A model refused before minting has no sealed request to carry its
        # inputs forward. Keep those sources before its failure envelope,
        # stopping at a model whose invocation already owns its history.
        # The iterative walk also covers a sequence of unavailable models.
        def recover_unstarted_sources(sources)
          pending = sources.reverse
          expanded = Set.new
          recovered = []
          until pending.empty?
            source = pending.pop
            if source.model_task? && source.failure? && source.selected_model_invocation_id.nil? && expanded.add?(source.id)
              pending.push(source, *load_sources(source.input_from_node_keys).reverse)
            else
              recovered << source
            end
          end
          recovered.uniq(&:id)
        end
    end
  end
end
