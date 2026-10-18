module Executors
  module TaskOperations
    # A tool inherits the immutable declaration that created it. Standalone
    # authors may supply that same context explicitly on their tool step.
    module Context
      module_function

      def defaults(node)
        return Runs::Tasks::Step.model_defaults(node) if node.model_task?
        return node.operation_context if node.operation_context

        parent = node.expansion_parent
        return Runs::Tasks::Step.model_defaults(parent) if parent&.model_task?
        return defaults(parent) if parent&.tool_call?

        round = Runs::KernelTool.round_of(node)
        round ? Runs::Tasks::Step.model_defaults(round) : {}
      end

      def projection(node)
        values = defaults(node)
        { "tools" => Array(values["tools"]), "model_defaults" => values.except("tools", "environment"),
          "environment" => values["environment"] }.compact
      end
    end
  end
end
