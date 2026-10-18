module Rho
  module T3
    # The page's control routes over the setup operations `rho t3` uses: one
    # document with the status, the saved settings and both T3 directories,
    # and a project choice or a bearer saved through the daemon's plugin
    # settings writer.
    module Control
      SERVICE = { "reachable" => true, "orchestration_protocol" => 2 }.freeze

      def self.register(api, settings:, native:)
        setup = ->(ctx) { Setup.new(settings: settings, native: native, persist: persist(ctx)) }
        api.register_route("GET", "/t3") do |_request, ctx|
          [200, document(setup.call(ctx), ctx.config.plugin_configuration(NAME))]
        end
        api.register_route("POST", "/t3/project") { |request, ctx| choose_project(request, setup.call(ctx)) }
        api.register_route("POST", "/t3/token") { |request, ctx| save_token(request, setup.call(ctx)) }
      end

      # A local service is restart-only, so its saved choice waits for the
      # restart: saved but not applied, as the generic configuration route
      # reports a restart-only plugin. `facts` ride into the answer: the
      # project chosen, or that the bearer is saved.
      def self.persist(ctx)
        lambda do |operations:, **facts|
          applied = begin
            ctx.configure_plugin(NAME, operations: operations)
            true
          rescue Rho::Settings::ApplyError => error
            raise unless error.restart_required

            false
          end
          facts.transform_keys(&:to_s).merge("saved" => true, "applied" => applied, "restart_required" => !applied)
        end
      end

      # `status` describes the running instance and `configuration` the saved
      # one, which differ while a local service waits for a restart; the
      # bearer itself never leaves the daemon, `status.bearer` names its
      # owner. A missing connection setting or a failed read leaves its
      # directory null instead of failing the page, and neither read hides
      # the other.
      def self.document(setup, configuration)
        service, providers = agents(setup)
        { "status" => setup.status, "configuration" => configuration.reject { |key, _value| key == "token" },
          "service" => service, "projects" => projects(setup), "providers" => providers }
      end

      # An empty body asks a local service for a bearer of its own; a host
      # service's bearer is the one given.
      def self.save_token(request, setup)
        body = Rho::ControlServer.json_body(request)
        answer = case body.keys
        when [] then setup.save_token
        when ["token"] then setup.save_token(body.fetch("token"))
        else return Rho::Daemon::Refusal.malformed("Send the T3 bearer as token, or nothing to issue one for a local service")
        end
        [200, answer]
      rescue Rho::Settings::ApplyError => error
        Rho::Daemon::Refusal.new(status: 503, code: "settings_apply_failed", message: error.message, extra: { saved: true })
      rescue Rho::ConfigurationError => error
        Rho::Daemon::Refusal.malformed(error.message)
      rescue Error => error
        Rho::Daemon::Refusal.new(status: 502, code: "t3_unavailable", message: error.message)
      end

      def self.agents(setup)
        [SERVICE, setup.providers]
      rescue Error => error
        [{ "reachable" => false, "error" => error.message }, nil]
      end

      def self.projects(setup)
        setup.projects
      rescue Error
        nil
      end

      # Exactly one of `id`, a listed project, or `path`, an absolute path
      # whose exact project is reused before another is created.
      def self.choose_project(request, setup)
        body = Rho::ControlServer.json_body(request)
        answer = case body.keys
        when ["id"] then setup.select_project(body.fetch("id").to_s)
        when ["path"] then setup.create_project(body.fetch("path").to_s)
        else return Rho::Daemon::Refusal.malformed("Choose a T3 project by id, or create one from an absolute path")
        end
        [200, answer]
      rescue Rho::Settings::ApplyError => error
        Rho::Daemon::Refusal.new(status: 503, code: "settings_apply_failed", message: error.message, extra: { saved: true })
      rescue Rho::ConfigurationError => error
        Rho::Daemon::Refusal.malformed(error.message)
      rescue Uncertain => error
        Rho::Daemon::Refusal.new(status: 502, code: "t3_uncertain", message: error.message)
      rescue Error => error
        Rho::Daemon::Refusal.new(status: 502, code: "t3_unavailable", message: error.message)
      end
    end
  end
end
