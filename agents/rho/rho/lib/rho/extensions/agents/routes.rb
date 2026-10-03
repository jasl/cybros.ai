module Rho
  module Extensions
    module Agents
      # THE FOUR ROUTES, the
      # `skill_routes.rb` shape: `GET /agents` is the listing — the
      # kernel's rows and the scan's skipped files — read-only; `POST
      # /agents/sync` the declare edge past its tuple; `POST
      # /agents/publish {name}` the same edge with one definition PUT
      # under `steward`; `POST /agents/rm {name}` the removal, 200 with
      # the removed row (the `/skills/rm` shape) or the kernel's 404
      # relayed. Every kernel refusal crosses through the route table's
      # one exception map.
      module Routes
        class << self
          def register(api)
            api.register_route("GET", "/agents") { |_request, ctx| list(ctx) }
            api.register_route("POST", "/agents/sync") { |_request, ctx| sync(ctx) }
            api.register_route("POST", "/agents/publish") { |request, ctx| publish(request, ctx) }
            api.register_route("POST", "/agents/rm") { |request, ctx| remove(request, ctx) }
          end

          def list(ctx)
            answer = ctx.list_named_definitions
            (answer in Rho::Daemon::Refusal) ? answer : [200, answer]
          end

          # `{declared: [names], removed: [names], skipped: N}` — the
          # scan's skips and the kernel's per-file refusals counted together.
          def sync(ctx)
            edge = ctx.sync_named_definitions
            return edge if edge in Rho::Daemon::Refusal

            [200, { declared: edge.declared, removed: edge.removed, skipped: edge.skipped.length + edge.failed.length }]
          end

          # The scanned definition NAME, PUT under `steward`: the same row
          # flips; a name the scan does not hold is not this daemon's to publish.
          def publish(request, ctx)
            name = named(request)
            return name if name in Rho::Daemon::Refusal

            definition = Rho::Agents.scan(root: ctx.environment.root).find(name)
            return no_definition(name) if definition.nil?

            edge = ctx.sync_named_definitions(publish: name)
            return edge if edge in Rho::Daemon::Refusal

            answer = edge.answers[name]
            if answer.nil?
              return Rho::Daemon::Refusal.new(status: 422, code: "declaration_failed",
                message: "the kernel refused #{name}'s declaration; the daemon's log names the code")
            end

            [200, { agent: answer.to_h.merge(configuration: answer.configuration.to_h), path: definition.path,
                    root: ctx.environment.root }]
          end

          def remove(request, ctx)
            name = named(request)
            return name if name in Rho::Daemon::Refusal

            answer = ctx.remove_named_definition(name)
            (answer in Rho::Daemon::Refusal) ? answer : [200, answer.merge(root: ctx.environment.root)]
          end

          private

            def named(request)
              name = ControlServer.json_body(request)["name"].to_s
              name.empty? ? Rho::Daemon::Refusal.malformed("name is required") : name
            end

            def no_definition(name)
              Rho::Daemon::Refusal.new(status: 404, code: "definition_not_found",
                message: "no definition named #{name}; rho agents lists them")
            end
        end
      end
    end
  end
end
