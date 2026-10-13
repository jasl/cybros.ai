module Rho
  module Extensions
    module Agents
      # Bot identity authoring. Executable policy is selected by Preset UUID.
      module Routes
        POLICY_KEYS = %w[name description display_name preset_public_id audience welcome_message subagent].freeze
        SETTINGS_KEYS = %w[agent_public_id home_workspace_public_id audience preset_public_id welcome_message subagent].freeze

        class << self
          def register(api)
            api.register_route("GET", "/agents") { |_request, ctx| list(ctx) }
            api.register_route("PUT", "/agents") { |request, ctx| declare(request, ctx) }
            api.register_route("PUT", "/agents/settings") { |request, ctx| settings(request, ctx) }
            api.register_route("POST", "/agents/rm") { |request, ctx| remove(request, ctx) }
          end

          def list(ctx)
            answer = ctx.list_named_definitions
            (answer in Rho::Daemon::Refusal) ? answer : [200, answer]
          end

          def declare(request, ctx)
            body = ControlServer.json_body(request)
            unknown = body.keys - POLICY_KEYS
            return Rho::Daemon::Refusal.malformed("unknown fields: #{unknown.join(", ")}") unless unknown.empty?

            name = body["name"].to_s
            return Rho::Daemon::Refusal.malformed("name is required: #{Rho::Agents::NAME_RULE}") unless name.match?(Rho::Agents::NAME_FORMAT)

            description = body["description"].to_s.strip
            return Rho::Daemon::Refusal.malformed("description is required") if description.empty?

            audience = audience_of(body)
            return audience if audience in Rho::Daemon::Refusal
            if body.key?("welcome_message") && !body["welcome_message"].nil? && String.try_convert(body["welcome_message"]).nil?
              return Rho::Daemon::Refusal.malformed("welcome_message must be a string or null")
            end

            if body.key?("subagent") && body["subagent"] != true && body["subagent"] != false
              return Rho::Daemon::Refusal.malformed("subagent must be a boolean")
            end

            answer = ctx.declare_named_definition(name: name, description: description,
              preset_public_id: optional_text(body["preset_public_id"]), display_name: optional_text(body["display_name"]),
              audience: audience, welcome_message: body.fetch("welcome_message", BotSettings::KEEP),
              subagent: body.fetch("subagent", BotSettings::KEEP))
            return answer if answer in Rho::Daemon::Refusal

            [200, { agent: answer.to_h.merge(configuration: answer.configuration.to_h) }]
          end

          def remove(request, ctx)
            name = ControlServer.json_body(request)["name"].to_s
            return Rho::Daemon::Refusal.malformed("name is required") if name.empty?

            answer = ctx.remove_named_definition(name)
            (answer in Rho::Daemon::Refusal) ? answer : [200, answer]
          end

          def settings(request, ctx)
            body = ControlServer.json_body(request)
            unknown = body.keys - SETTINGS_KEYS
            return Rho::Daemon::Refusal.malformed("unknown fields: #{unknown.join(", ")}") unless unknown.empty?

            agent = body["agent_public_id"].to_s
            return Rho::Daemon::Refusal.malformed("agent_public_id is required") if agent.empty?
            return Rho::Daemon::Refusal.malformed("at least one Bot setting is required") if (body.keys - ["agent_public_id"]).empty?

            audience = audience_of(body)
            return audience if audience in Rho::Daemon::Refusal
            if body.key?("welcome_message") && !body["welcome_message"].nil? && String.try_convert(body["welcome_message"]).nil?
              return Rho::Daemon::Refusal.malformed("welcome_message must be a string or null")
            end

            if body.key?("subagent") && body["subagent"] != true && body["subagent"] != false
              return Rho::Daemon::Refusal.malformed("subagent must be a boolean")
            end

            fields = body.except("agent_public_id", "audience").transform_keys(&:to_sym)
            if fields.key?(:home_workspace_public_id) && fields[:home_workspace_public_id] == ""
              return Rho::Daemon::Refusal.malformed("home_workspace_public_id must be a public id or null")
            end
            answer = ctx.replace_bot_settings(agent_public_id: agent, audience: audience, **fields)
            (answer in Rho::Daemon::Refusal) ? answer : [200, answer]
          end

          private

            def audience_of(body)
              return BotSettings::KEEP unless body.key?("audience")
              return body["audience"] if BotSettings::AUDIENCES.include?(body["audience"])

              Rho::Daemon::Refusal.malformed("audience must be owner or external")
            end

            def optional_text(value)
              text = value.to_s
              text.strip.empty? ? nil : text
            end
        end
      end
    end
  end
end
