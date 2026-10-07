# This fixture declares two independent skill sources through the member API.
# Nexus assembles each source's exact schema and concrete route.
module SkillsAuthor
  NAME = "e2e.skills-author".freeze

  def self.register(api)
    api.register_route("POST", "/e2e/skill-catalog") do |request, ctx|
      ctx.member_plane(request, body: true) do |client, _workspace, _about, body|
        ctx.declare_profile
        configuration = client.profile.fetch.configuration.to_h.transform_keys(&:to_sym)
        explicit = configuration.fetch(:tool_definitions).reject { |entry| entry.dig("route", "tool_name") == "skill" }
        sources = configuration.slice(:kernel_tools, :runner_executor_public_ids)
          .merge(tool_definitions: explicit, runner_tool_names: nil).transform_keys(&:to_s)
        skills = body.fetch("runner_executor_public_ids").flat_map do |runner|
          client.tools.assemble(default_runner_executor_public_id: runner, configuration: sources).tool_definitions
            .select { |entry| entry.dig("route", "tool_name") == "skill" }
        end
        profile = client.profile.declare_configuration(**configuration.merge(
          tool_definitions: explicit + skills, runner_tool_names: []
        ))
        [200, { "configuration" => profile.configuration.to_h }]
      end
    end
  end
end
