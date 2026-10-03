module AgentLoops
  module Tasks
    # A node the tip names: enough to place against without loading the row.
    Known = Data.define(:key, :kind, :mark, :result_only) do
      def self.of(node, result_only: node&.task_kind == "script_task")
        return nil if node.nil?

        new(key: node.node_key, kind: node.task_kind, mark: node.continuation_source, result_only: result_only)
      end

      def initialize(key:, kind:, mark:, result_only: kind == "script_task") = super
    end
  end
end
