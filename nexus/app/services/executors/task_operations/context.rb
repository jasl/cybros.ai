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

      def executor_context(node)
        return node.operation_context["executor_context"] if node.operation_context&.key?("executor_context")

        values = defaults(node)
        (values["executor_contexts"] || node.run.agent_configuration&.executor_contexts || {})[
          node.target_executor_public_id || Executor.address_for(node.run.execution_agent)&.public_id
        ]
      end

      def projection(node)
        values = defaults(node)
        { "tools" => Array(values["tools"]), "model_defaults" => values.except("tools", "environment"),
          "environment" => values["environment"] }.compact
      end
    end
  end
end
