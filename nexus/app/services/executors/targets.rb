module Executors
  # Acceptance freezes destination and environment once. Receipt replay precedes
  # this boundary, and the scheduler reads only the resulting immutable facts.
  module Targets
    module_function

    def prepare(agent_run:, payload:, inherited: nil, model_origin: false)
      route = payload.delete("runner_route")
      context = payload["operation_context"].to_h
      environment = context["environment"] || inherited&.fetch("environment", nil)
      tools = payload["tool_definitions"] || context["tools"]
      imports = payload.delete("tool_imports")
      if imports
        return :context_not_authorable if model_origin || environment

        result = Tools::Assemble.call(principal: agent_run.answering_user, tool_definitions: tools,
          kernel_tools: imports["kernel_tools"], runner_executor_public_ids: imports["runner_executor_public_ids"],
          runner_tool_names: imports["runner_tool_names"], runner: agent_run.default_runner)
        return result.refusal if result.refused?

        tools = result.definitions.presence
        environment = result.environment
        if payload["type"] == AgentRunTasks::ModelTask.sti_name
          payload["tool_definitions"] = tools
        else
          context["tools"] = tools
        end
      end
      if route
        public_id = route.fetch("runner_executor_public_id") do
          environment ? environment["default_runner_executor_public_id"] : agent_run.default_runner&.public_id
        end
        return :runner_target_required if public_id.nil?

        target = runner(agent_run, public_id)
        unless model_origin
          return :runner_not_eligible unless target&.eligible_for?(agent_run.answering_user)
          return :tool_not_served unless target.served?(payload.fetch("tool_name"))
        end
        payload["target_executor_id"] = target&.id
        payload["target_executor_public_id"] = public_id
      end
      if tools && environment.nil?
        targets = Array(tools).filter_map { |entry| entry["route"] }.map { |entry| entry.fetch("runner_executor_public_id") }.uniq
        executors = targets.map { |id| runner(agent_run, id) }
        return :runner_not_eligible unless executors.all? { |executor| executor&.eligible_for?(agent_run.answering_user) }
        Array(tools).each do |entry|
          next unless entry["route"]
          target = executors.find { |executor| executor.public_id == entry.fetch("route").fetch("runner_executor_public_id") }
          return :tool_not_served unless target.served?(entry.fetch("route").fetch("tool_name"))
        end
        environment = snapshot(agent_run, tools, executors)
      elsif environment.nil? && (payload["type"] == AgentRunTasks::ModelTask.sti_name || route)
        environment = snapshot(agent_run, tools, [])
      end
      if environment && !environment.key?("skills")
        environment = environment.merge("skills" => skills(agent_run, tools))
      end
      # Generated tools read their parent's declaration instead of copying
      # schemas onto every fan member. Standalone tools own their context.
      if environment && (payload["type"] == AgentRunTasks::ModelTask.sti_name || inherited.nil?)
        payload["operation_context"] = context.merge("environment" => environment)
      end
      context = payload["operation_context"]
      if context && !Nexus::SizeBounds.json_within?(:snapshot_bound, context)
        return Nexus::SizeBounds::REJECTION
      end
      nil
    end

    def runner(agent_run, public_id)
      TaskExecutor.where(account_id: agent_run.account_id, executor_kind: :runner).find_by(public_id: public_id)
    end

    def snapshot(agent_run, tools, executors)
      {
        "default_runner_executor_public_id" => agent_run.default_runner&.public_id,
        "executors" => executors.map do |executor|
          { "runner_executor_public_id" => executor.public_id, "environment" => executor.environment }
        end,
        "runner_candidates" => [],
        "skills" => skills(agent_run, tools),
      }
    end

    def skills(agent_run, tools)
      AgentRuns::Skills::Catalog.for(
        tools: tools, address: Address.agent_address(agent_run), workspace_id: agent_run.workspace_id,
        human: agent_run.memory_principal.controlling_human
      ).map { |entry| entry.to_h.stringify_keys }
    end
  end
end
