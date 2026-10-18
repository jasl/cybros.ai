# This fixture selects two independent skill sources through the member API.
# Nexus assembles each source's exact schema and concrete route; the author hook
# places them on the accepted execution rather than changing the live profile.
module SkillsAuthor
  NAME = "e2e.skills-author".freeze

  def self.register(api)
    selected_skills = []
    api.register_route("POST", "/e2e/skill-catalog") do |request, ctx|
      ctx.member_plane(request, body: true) do |client, _workspace, _about, body|
        ctx.declare_profile
        configuration = client.profile.fetch.configuration.to_h.transform_keys(&:to_sym)
        explicit = configuration.fetch(:tool_definitions).reject { |entry| entry.dig("route", "tool_name") == "skill" }
        sources = configuration.slice(:kernel_tools, :runner_executor_public_ids)
          .merge(tool_definitions: explicit, runner_tool_names: nil).transform_keys(&:to_s)
        selected_skills = body.fetch("runner_executor_public_ids").flat_map do |runner|
          client.tools.assemble(default_runner_executor_public_id: runner, configuration: sources).tool_definitions
            .select { |entry| entry.dig("route", "tool_name") == "skill" }
        end
        [200, { "tool_definitions" => selected_skills }]
      end
    end

    api.on(:turn_author) do |draft, _ctx|
      declaration = draft.body.fetch("agent_configuration")
      explicit = declaration.fetch("tool_definitions").reject { |entry| entry.dig("route", "tool_name") == "skill" }
      captured = declaration.merge("tool_definitions" => explicit + selected_skills, "runner_tool_names" => [])
      draft.with(body: draft.body.merge("agent_configuration" => captured))
    end
  end
end
