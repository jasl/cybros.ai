module AgentLoops
  module Skills
    # THE SKILL LOAD'S EXECUTOR: the
    # one kernel tool routed PER CALL by its argument's SOURCE. `address`
    # is `Executors::Address`'s early return for the routed-by-source
    # canonical and reads ONE thing off the call — `tool_input["name"]` —
    # asking ONE question of it: is it a name the bound runner or the
    # agent address announced under `documents`? Announced → the SAME
    # `skill` row is dispatched to its announcer (which must serve `skill`
    # and be eligible, else `tool_not_served` — never a park), and the
    # inbox lists it with `tool_name: "skill"`, the model's `tool_alias`,
    # `scope` and `tool_input: {name}`; the announcer claims, reads the
    # file it announced, commits, and the commit's content is the call's
    # result. Otherwise the row runs in-process: the kernel's own
    # `skills/` rows answer it (`Memory::Run#skill`, `workspace/` before
    # `user/`) or the result is the error `skill_unknown`.
    #
    # This is the only tool argument read by executor routing — one tool,
    # one key, read as an ADDRESS (membership in an announced list, the
    # same kind of read `served?(name)` makes of a tool name) and never as
    # a meaning; no schema is validated (a malformed `name` matches no
    # announcement and runs in-process, where it lands on `skill_unknown`).
    # It reads no kernel row: zero memory queries at start.
    module Dispatch
      WIRE_NAME = Nexus::ToolRegistry.entry(Catalog::CANONICAL).name

      module_function

      def address(node)
        agent_loop = node.agent_loop
        name = String.try_convert(node.tool_input["name"])
        principal = agent_loop.answering_user
        announcers(agent_loop).each do |executor, role|
          next unless Catalog.announces?(executor, name)
          return dispatched(executor, role) if Executors::Address.serves?(executor, WIRE_NAME, principal)

          return Executors::Address::Refusal.new(error_key: Executors::Address::TOOL_NOT_SERVED,
            detail: "#{name} is announced by #{executor.display_name}, which does not serve #{WIRE_NAME}")
        end

        Executors::Address::Decision.new(executor: nil, role: nil, status: "running",
          effect_profile: Nexus::ToolRegistry.effect_profile_for(Catalog::CANONICAL))
      end

      # The two announcers in addressing order: the bound runner, then the
      # declaring agent's address.
      def announcers(agent_loop)
        [[agent_loop.bound_runner, "runner"],
         [Executors::Address.agent_address(agent_loop), "agent_application"]]
      end

      def dispatched(executor, role)
        Executors::Address::Decision.new(executor: executor, role: role, status: "dispatched",
          effect_profile: executor.effect_profile_for(WIRE_NAME))
      end
    end
  end
end
