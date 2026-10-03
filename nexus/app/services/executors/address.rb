module Executors
  # THE ONE ADDRESSING SITE: at a parked node's start, who it is addressed to — written on the
  # row once per execution generation and read by the inbox and the claim, so no door asks the
  # registry again. A tool call, in order: a live kernel name runs in-process with the
  # registry's profile and no addressee UNLESS its namespace is overridden in the loop's
  # workspace — then it is addressed to the named provider or fails `tool_not_served` with no
  # fallback; this branch is the only way a kernel name leaves the kernel by a workspace's map,
  # and `skill` leaves it by its argument's announcer (`AgentLoops::Skills::Dispatch`, the one
  # source-routed name, decided before the map): both precede the runner, the agent address and
  # the pool, so a kernel name never forms a pool however many providers announce it. Then the
  # host's bound runner if it announced the name; the loop's declaring agent's address if it
  # did; else the POOL — `addressed_role: tools_provider` and NO executor — when any tools
  # provider eligible for the loop's principal announced it (Executors::Pool: the members, and
  # the strictest announced profile with the shortest park frozen on the row); else
  # `tool_not_served`, an error the model reads on the next round. An await: tokened → a holder
  # outside the kernel has the proof, no addressee; tokenless → the ask, addressed to the agent
  # address or to nobody — the person's door only. Eligibility is read of a tool's addressee for
  # the loop's frozen principal; an ask's addressee is a person's clock and is not asked.
  # Lock-free reads throughout: `task_executors` sits above `agent_loops` on the ladder.
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
      agent_loop = node.agent_loop
      return AgentLoops::Skills::Dispatch.address(node) if
        Nexus::ToolRegistry.routed_by_source?(Nexus::ToolRegistry.resolve(name))
      if Nexus::ToolRegistry.kernel_name?(name)
        canonical = Nexus::ToolRegistry.resolve(name)
        if canonical.start_with?("nexus.memory.") && agent_loop.workspace.tool_provider_override_for(name)
          context = MemoryDocuments::Context.new(workspace: agent_loop.workspace, conversation: agent_loop.conversation,
            principal: agent_loop.creating_user, configuration: agent_loop.memory_context)
          refusal = context.tool_refusal(verb: canonical, input: node.tool_input)
          return Refusal.new(error_key: refusal.to_s, detail: "memory binding does not permit this call") if refusal
        end
        return kernel(agent_loop, name)
      end

      # The principal every executor is judged for is the ANSWERER: the
      # binding written for it at create must be reachable at every call,
      # whoever spoke the turn.
      principal = agent_loop.answering_user
      runner = agent_loop.bound_runner
      if serves?(runner, name, principal)
        return Decision.new(executor: runner, role: "runner", status: "dispatched",
          effect_profile: runner.effect_profile_for(name))
      end

      address = agent_address(agent_loop)
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

    def await(node)
      unless node.answers_to_write_standing?
        return Decision.new(executor: nil, role: nil, effect_profile: nil, status: "dispatched")
      end

      address = agent_address(node.agent_loop)
      Decision.new(executor: address, role: ("agent_application" if address),
        effect_profile: nil, status: "awaiting_input")
    end

    # The kernel's own name: in-process, unless the loop's workspace
    # overrides its namespace. The read answers nil for every reserved and
    # non-kernel name, so `compose` never consults the map. NO kernel
    # fallback: "a tool name resolves to exactly one providing authority"
    # (the four sources) — a provider that is gone, revoked, out of scope
    # or no longer announcing the verb fails the call, an error the model
    # reads on its next round.
    def kernel(agent_loop, name)
      workspace = agent_loop.workspace
      override = workspace.tool_provider_override_for(name)
      if override.nil?
        return Decision.new(executor: nil, role: nil, status: "running",
          effect_profile: Nexus::ToolRegistry.effect_profile_for(name))
      end

      provider = workspace.tool_provider_for(name)
      if serves?(provider, name, agent_loop.answering_user)
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

    # Derived at each start, never frozen on the loop: a reconnected
    # profile's NEW address serves the rest of its turn.
    def agent_address(agent_loop)
      profile = agent_loop.declaring_profile
      TaskExecutor.address_for(profile) if profile&.active?
    end
  end
end
