module Executors
  module TaskOperations
    # A tool inherits the immutable declaration that created it. Standalone
    # authors may supply that same context explicitly on their tool step.
    module Context
      module_function

      def defaults(node)
        return Runs::Tasks::Step.model_defaults(node) if node.model_task?
        return node.operation_context.except("executor_context") if node.operation_context

        parent = node.expansion_parent
        return Runs::Tasks::Step.model_defaults(parent) if parent&.model_task?
        return defaults(parent) if parent&.tool_call?

        round = Runs::KernelTool.round_of(node)
        round ? Runs::Tasks::Step.model_defaults(round) : {}
      end

      def executor_context(node, executor: nil)
        return node.operation_context["executor_context"] if node.operation_context&.key?("executor_context")

        public_id = executor_public_id(node, executor: executor)
        return if public_id.nil?

        values = defaults(node)
        (values["executor_contexts"] || node.run.agent_configuration&.executor_contexts || {})[public_id]
      end

      def projection(node)
        values = defaults(node)
        { "tools" => Array(values["tools"]), "model_defaults" => values.except("tools", "environment"),
          "environment" => values["environment"] }.compact
      end

      def executor_public_id(node, executor:)
        return node.claimed_by_executor_public_id if node.claimed_by_executor_public_id
        return node.target_executor_public_id if node.target_executor_public_id
        # Approval addresses receive a notification, not execution. Dispatch
        # stamps started_at; denied or expired approval rows never acquire it.
        return if node.started_at.nil?

        node.addressed_executor&.public_id || (executor&.public_id if Pool.row?(node))
      end
      private_class_method :executor_public_id
    end
  end
end
