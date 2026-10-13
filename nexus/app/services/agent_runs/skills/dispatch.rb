module AgentRuns
  module Skills
    # Skill loads follow the source saved in the execution catalog. A missing
    # or withdrawn source never falls through to another same-named document.
    module Dispatch
      WIRE_NAME = Nexus::ToolRegistry.entry(Catalog::CANONICAL).name

      module_function

      def address(node)
        environment = Executors::TaskOperations::Context.defaults(node)["environment"].to_h
        callable = node.tool_alias || node.tool_name
        document = Array(environment["skills"]).find do |entry|
          entry["callable"] == callable && entry["name"] == node.tool_input["name"]
        end
        return kernel if document.nil?
        if document["executor_public_id"]
          executor = TaskExecutor.find_by(account_id: node.account_id, public_id: document["executor_public_id"])
          unless Catalog.announces?(executor, document["name"]) &&
              Executors::Address.serves?(executor, WIRE_NAME, node.agent_run.answering_user)
            return refused("the skill's source no longer serves this document")
          end
          return Executors::Address::Decision.new(executor: executor, role: document.fetch("source"),
            status: "dispatched", effect_profile: executor.effect_profile_for(WIRE_NAME))
        end
        kernel
      end

      def kernel
        Executors::Address::Decision.new(executor: nil, role: nil, status: "running",
          effect_profile: Nexus::ToolRegistry.effect_profile_for(Catalog::CANONICAL))
      end

      def refused(detail)
        Executors::Address::Refusal.new(error_key: Executors::Address::TOOL_NOT_SERVED, detail: detail)
      end
    end
  end
end
