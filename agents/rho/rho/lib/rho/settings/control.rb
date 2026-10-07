module Rho
  class Settings
    module Control
      def self.register(api)
        api.register_route("GET", "/settings") { |_request, ctx| [200, document(ctx)] }
        api.register_route("PATCH", "/settings") { |request, ctx| update(request, ctx) }
        api.register_route("GET", "/settings/status") { |_request, ctx| status(ctx) }
      end

      def self.document(ctx)
        config = ctx.config
        public_url = config.nexus_public_url || ctx.home.base_url
        {
          settings: config.to_h.slice(*Rho::Settings::PUBLIC_KEYS),
          extensions: ctx.inventory,
          nexus: { api_url: ctx.home.base_url, public_url: public_url,
                   model_settings_url: "#{public_url}/admin/model_providers" },
          deployment: config.to_h.slice(*Rho::Settings::DEPLOYMENT_KEYS),

        }
      end

      def self.update(request, ctx)
        changes = ControlServer.json_body(request)
        ctx.update_settings(changes)
        [200, document(ctx)]
      rescue Rho::ConfigurationError => error
        Rho::Daemon::Refusal.new(status: 422, code: "settings_invalid", message: error.message)
      rescue Rho::Settings::ApplyError => error
        Rho::Daemon::Refusal.new(status: 503, code: "settings_apply_failed", message: error.message,
          extra: { saved: true, applied: error.applied, published: error.published, restart_required: error.restart_required })
      rescue StateFile::PublishedError => error
        Rho::Daemon::Refusal.new(status: 503, code: "settings_durability_uncertain", message: error.message,
          extra: { saved: true, published: true, applied: false })
      end

      def self.status(ctx)
        result = ctx.member_plane(require_workspace: false) do |client|
          eligible = client.models.list(workload: "text_generation").select do |row|
            row.available && row.capabilities.fetch("tool_calls", false)
          end
          [200, { connected: true,
                  model: { default_model: ctx.config.default_model,
                           ready: eligible.any? { |row| row.ref == ctx.config.default_model },
                           eligible: eligible.map { |row| row.to_h.merge(pricing: row.pricing.to_h) } },
                  defaults: defaults(ctx) }]
        end
        return result unless result in Rho::Daemon::Refusal

        if result.code == "member_plane_unavailable"
          [200, { connected: false,
                  model: { default_model: ctx.config.default_model, ready: false, eligible: [] },
                  defaults: defaults(ctx) }]
        else
          result
        end
      end

      def self.defaults(ctx)
        { runner_executor_public_id: ctx.runner_selection({}),
          tools_ready: !ctx.runner_snapshot.dig(:runner, :announced).nil? }
      end
    end
  end
end
