module Executors
  # Resolves the inbox addressee when a Task becomes ready. A frozen Runner
  # target takes precedence and either serves the call or refuses it. Other
  # skills retain their frozen source; other kernel names use the registry or
  # their explicit workspace override. Ordinary names use the declaring Agent
  # application's address, then the eligible tool-provider pool. The host's
  # current default never participates in delivery.
  #
  # Pool delivery freezes the strictest effect profile and shortest timeout.
  # A tokened await has no addressee; a tokenless ask uses the Agent application
  # address when present. Tool eligibility uses the Run's answering principal.
  # Lock-free reads throughout: `task_executors` sits above `agent_runs` on the ladder.
  module Address
    Decision = Data.define(:executor, :role, :effect_profile, :status) do
      def refused? = false
    end

    Refusal = Data.define(:error_key, :detail) do
      def refused? = true
    end

    TOOL_NOT_SERVED = "tool_not_served".freeze

    module_function

    def call(node)
      node.await? ? await(node) : tool(node)
    end

    def tool(node)
      name = node.tool_name
      agent_run = node.agent_run
      return targeted(node) if node.target_executor_public_id
      return AgentRuns::Skills::Dispatch.address(node) if
        Nexus::ToolRegistry.routed_by_source?(Nexus::ToolRegistry.resolve(name))
      if Nexus::ToolRegistry.kernel_name?(name)
        canonical = Nexus::ToolRegistry.resolve(name)
        if canonical.start_with?("nexus.memory.") && agent_run.workspace.tool_provider_override_for(name)
          context = MemoryDocuments::Context.new(workspace: agent_run.workspace, conversation: agent_run.conversation,
            principal: agent_run.creating_user, configuration: agent_run.memory_context)
          refusal = context.tool_refusal(verb: canonical, input: node.tool_input)
          return Refusal.new(error_key: refusal.to_s, detail: "memory binding does not permit this call") if refusal
        end
        return kernel(agent_run, name)
      end

      # Executor eligibility belongs to the answerer, whoever spoke the turn.
      principal = agent_run.answering_user
      address = agent_address(agent_run)
      if serves?(address, name, principal)
        return Decision.new(executor: address, role: "agent_application", status: "dispatched",
          effect_profile: address.effect_profile_for(name))
      end

      members = Pool.members(name, principal)
      if members.any?
        return Decision.new(executor: nil, role: Pool::ROLE, status: "dispatched",
          effect_profile: Pool.effect_profile(members, name))
      end

      Refusal.new(error_key: TOOL_NOT_SERVED, detail: "no executor announces #{name} for this principal")
    end

    def targeted(node)
      target = node.target_executor
      if target && target.public_id == node.target_executor_public_id &&
          serves?(target, node.tool_name, node.agent_run.answering_user)
        if Nexus::ToolRegistry.routed_by_source?(Nexus::ToolRegistry.resolve(node.tool_name)) &&
            !AgentRuns::Skills::Catalog.loadable?(node, target)
          return Refusal.new(error_key: TOOL_NOT_SERVED, detail: "the selected Runner no longer announces this skill")
        end
        return Decision.new(executor: target, role: "runner", status: "dispatched",
          effect_profile: target.effect_profile_for(node.tool_name))
      end
      Refusal.new(error_key: TOOL_NOT_SERVED, detail: "the selected Runner no longer serves #{node.tool_name}")
    end

    def await(node)
      unless node.answers_to_write_standing?
        return Decision.new(executor: nil, role: nil, effect_profile: nil, status: "dispatched")
      end

      address = agent_address(node.agent_run)
      Decision.new(executor: address, role: ("agent_application" if address),
        effect_profile: nil, status: "awaiting_input")
    end

    # The kernel's own name: in-process, unless the Run's workspace
    # overrides its namespace. The read answers nil for every reserved and
    # non-kernel name, so `wait` never consults the map. NO kernel
    # fallback: "a tool name resolves to exactly one providing authority"
    # (the four sources) — a provider that is gone, revoked, out of scope
    # or no longer announcing the verb fails the call, an error the model
    # reads on its next round.
    def kernel(agent_run, name)
      workspace = agent_run.workspace
      override = workspace.tool_provider_override_for(name)
      if override.nil?
        return Decision.new(executor: nil, role: nil, status: "running",
          effect_profile: Nexus::ToolRegistry.effect_profile_for(name))
      end

      provider = workspace.tool_provider_for(name)
      if serves?(provider, name, agent_run.answering_user)
        return Decision.new(executor: provider, role: Pool::ROLE, status: "dispatched",
          effect_profile: provider.effect_profile_for(name))
      end

      Refusal.new(error_key: TOOL_NOT_SERVED, detail: override_detail(provider, override, name))
    end

    def override_detail(provider, override, name)
      namespace = Nexus::ToolRegistry.namespace(Nexus::ToolRegistry.resolve(name))
      if provider.nil? || provider.revoked?
        "#{namespace} is served by a provider that is no longer available (#{override})"
      elsif !provider.served?(name)
        "#{namespace} is served by #{provider.display_name}, which does not announce #{name}"
      else
        "#{namespace} is served by #{provider.display_name}, which is not in scope for this loop's principal"
      end
    end

    def serves?(executor, name, principal)
      executor.present? && executor.served?(name) && executor.eligible_for?(principal)
    end

    # Derived at each start, never frozen on the Run: a reconnected
    # profile's NEW address serves the rest of its turn.
    def agent_address(agent_run)
      profile = agent_run.declaring_profile
      TaskExecutor.address_for(profile) if profile&.active?
    end
  end
end
