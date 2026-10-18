module Rho
  module Extensions
    module Agents
      module Documents
        def self.register(api)
          api.register_route("POST", "/agents/duplicate") { |request, ctx| duplicate(request, ctx) }
        end

        def self.duplicate(request, ctx)
          body = ControlServer.json_body(request)
          unknown = body.keys - %w[source_name name display_name audience]
          return Daemon::Refusal.malformed("unknown fields: #{unknown.join(", ")}") unless unknown.empty?

          listing = ctx.list_named_agents
          return listing if listing in Daemon::Refusal

          row = listing.fetch(:bots).find { |candidate| candidate.fetch(:name) == body.fetch("source_name") && !candidate[:from] && !candidate[:registered] }
          return Daemon::Refusal.new(status: 404, code: "not_found", message: "Bot not found") unless row

          name = body.fetch("name").to_s
          return Daemon::Refusal.malformed("name must use #{Rho::Agents::NAME_RULE}") unless name.match?(Rho::Agents::NAME_FORMAT)
          audience = body.fetch("audience", row.fetch(:audience))
          return Daemon::Refusal.malformed("audience must be owner or external") unless BotSettings::AUDIENCES.include?(audience)

          answer = ctx.declare_named_agent(name: name, description: row.fetch(:description),
            display_name: body.fetch("display_name", row[:display_name]), preset_public_id: row.fetch(:preset_public_id),
            audience: audience, welcome_message: row[:welcome_message], subagent: row.fetch(:subagent), create_only: true)
          return answer if answer in Daemon::Refusal

          [200, { agent: answer.to_h.merge(configuration: answer.configuration.to_h) }]
        rescue KeyError => error
          Daemon::Refusal.parameter_missing(error.key)
        end
      end
    end
  end
end
