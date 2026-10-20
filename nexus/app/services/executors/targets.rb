module Executors
  # Acceptance freezes destination and environment once. Receipt replay precedes
  # this boundary, and the scheduler reads only the resulting immutable facts.
  module Targets
    module_function

    def prepare(run:, payload:, inherited: nil, model_origin: false)
      return nil if payload["type"] == Tasks::ModelTask.sti_name && payload["workload"] == "image_generation"

      route = payload.delete("tool_route")
      context = payload["operation_context"].to_h
      if inherited && (context.key?("executor_contexts") || context.key?("executor_context"))
        return :context_not_authorable if model_origin &&
          (context["executor_context"] || context["executor_contexts"] != inherited["executor_contexts"])
      end
      environment = context["environment"] || inherited&.fetch("environment", nil)
      tools = payload["tool_definitions"] || context["tools"]
      imports = payload.delete("tool_imports")
      if imports
        return :context_not_authorable if model_origin || environment

        result = Tools::Assemble.call(principal: run.answering_user, tool_definitions: tools,
          kernel_tools: imports["kernel_tools"], runner_executor_public_ids: imports["runner_executor_public_ids"],
          runner_tool_names: imports["runner_tool_names"], mcp_tools: imports["mcp_tools"], runner: run.default_runner)
        return result.refusal if result.refused?

        tools = result.definitions.presence
        environment = result.environment
        if payload["type"] == Tasks::ModelTask.sti_name
          payload["tool_definitions"] = tools
        else
          context["tools"] = tools
        end
      end
      if route && route.fetch("kind") == "mcp"
        id = route.fetch("connection_public_id")
        unless model_origin
          connection = run.account.mcp_connections.find_by(public_id: id)
          return :mcp_connection_unavailable unless
            connection&.tool_available?(agent: run.answering_user, name: payload.fetch("tool_name"))
        end
        payload["mcp_connection_public_id"] = id
      elsif route
        public_id = route.fetch("runner_executor_public_id") do
          environment ? environment["default_runner_executor_public_id"] : run.default_runner&.public_id
        end
        return :runner_target_required if public_id.nil?

        target = runner(run, public_id)
        unless model_origin
          return :runner_not_eligible unless target&.eligible_for?(run.answering_user)
          return :tool_not_served unless target.served?(payload.fetch("tool_name"))
        end
        payload["target_executor_id"] = target&.id
        payload["target_executor_public_id"] = public_id
      end
      if tools && environment.nil?
        routes = Array(tools).filter_map { |entry| entry["route"] }
        mcp_routes = routes.select { |entry| entry.fetch("kind") == "mcp" }
        connections = run.account.mcp_connections.where(public_id: mcp_routes.map { |entry| entry.fetch("connection_public_id") })
          .includes(:owner).index_by(&:public_id)
        mcp_routes.each do |entry|
          connection = connections[entry.fetch("connection_public_id")]
          return :mcp_connection_unavailable unless
            connection&.tool_available?(agent: run.answering_user, name: entry.fetch("tool_name"))
        end
        targets = routes.select { |entry| entry.fetch("kind") == "runner" }.map { |entry| entry.fetch("runner_executor_public_id") }.uniq
        executors = targets.map { |id| runner(run, id) }
        return :runner_not_eligible unless executors.all? { |executor| executor&.eligible_for?(run.answering_user) }
        Array(tools).each do |entry|
          next unless entry.dig("route", "kind") == "runner"
          target = executors.find { |executor| executor.public_id == entry.fetch("route").fetch("runner_executor_public_id") }
          return :tool_not_served unless target.served?(entry.fetch("route").fetch("tool_name"))
        end
        environment = snapshot(run, tools, executors)
      elsif environment.nil? && (payload["type"] == Tasks::ModelTask.sti_name || route)
        environment = snapshot(run, tools, [])
      end
      if environment && !environment.key?("skills")
        environment = environment.merge("skills" => skills(run, tools))
      end
      # Generated tools read their parent's declaration instead of copying
      # schemas onto every fan member. Standalone tools own their context.
      if environment && (payload["type"] == Tasks::ModelTask.sti_name || inherited.nil?)
        payload["operation_context"] = context.merge("environment" => environment)
      end
      contexts = context["executor_contexts"] || inherited&.fetch("executor_contexts", nil) || run.agent_configuration&.executor_contexts
      contexts = Nexus::ExecutorContexts.normalize(contexts) if contexts
      if context["executor_context"] && contexts
        target_id = payload["target_executor_public_id"] || Executor.address_for(run.execution_agent)&.public_id
        return :executor_context_mismatch if contexts.key?(target_id) && contexts[target_id] != context["executor_context"]
      end
      if contexts && payload["type"] == Tasks::ModelTask.sti_name
        payload["operation_context"] = payload.fetch("operation_context", {}).merge("executor_contexts" => contexts)
      end
      context = payload["operation_context"]
      if context && !Nexus::SizeBounds.json_within?(:snapshot_bound, context)
        return Nexus::SizeBounds::REJECTION
      end
      nil
    end

    def runner(run, public_id)
      Executor.where(account_id: run.account_id, executor_kind: :runner).find_by(public_id: public_id)
    end

    def snapshot(run, tools, executors)
      {
        "default_runner_executor_public_id" => run.default_runner&.public_id,
        "executors" => executors.map do |executor|
          { "runner_executor_public_id" => executor.public_id, "environment" => executor.environment }
        end,
        "runner_candidates" => [],
        "skills" => skills(run, tools),
      }
    end

    def skills(run, tools)
      agent = run.execution_agent
      # Sharing an application transport grants no publisher document sources.
      address = Executor.address_for(agent) if agent&.active?
      Runs::Skills::Catalog.for(
        tools: tools, address: address,
        context: MemoryDocuments::Context.new(workspace: run.workspace, conversation: run.conversation,
          principal: run.creating_user, configuration: run.memory_context, agent: run.execution_agent,
          execution: true)
      ).map { |entry| entry.to_h.stringify_keys }
    end
  end
end
