module AgentRuns
  module Runners
    class List
      def self.call(node:)
        return :not_running unless node.status == "running"

        environment = Executors::TaskOperations::Context.defaults(node).fetch("environment", {})
        result = {
          "current_runner_executor_public_id" => environment["default_runner_executor_public_id"],
          "runners" => environment.fetch("runner_candidates", []),
        }
        KernelTool.settle(node, result.to_json, title: "runner environments")
      end
    end
  end
end
