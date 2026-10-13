module Rho
  module Extensions
    module DefaultRunner
      # The two doors behind the verbs: discovery and default Runner selection. Both
      # reach the kernel through `ctx.member_plane`; the bindings through
      # the facade's store readers; nothing here holds state past one call.
      module Routes
        class << self
          def register(api)
            api.register_route("GET", "/runners") { |_request, ctx| runners(ctx) }
            api.register_route("POST", "/default_runner") { |request, ctx| set_default_runner(request, ctx) }
          end

          # THE LISTING: what discovery answers for this profile
          # — the runner kind alone — each with the kernel's presence word
          # (a FOREIGN executor's; this machine's own prints local truth in
          # `rho status`), its announced root and names, and this daemon's
          # marks: own, selected in the settings, and the followed hosts using
          # it as their default. Every document read refreshes the daemon's cache, and
          # the profile is refreshed from the complete eligible candidate list.
          def runners(ctx)
            ctx.member_plane(require_workspace: false) do |client, *|
              listed = client.executors.list(kind: "runner")
              listed.each { |document| ctx.learn_runner(document) }
              bindings = ctx.host_bindings
              selection = ctx.settings_runner
              rows = listed.map { |document| row(document, ctx, bindings, selection) }
              ctx.declare_profile
              [200, { runners: rows, selection: selection }]
            end
          end

          # A default chooses the environment described to subsequent turns.
          # Existing tasks and environment records retain their original targets.
          def set_default_runner(request, ctx)
            ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
              public_id = body["public_id"].to_s
              next Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?
              next Rho::Daemon::Refusal.malformed("executor_public_id is required") unless body.key?("executor_public_id")

              executor = body["executor_public_id"]&.to_s
              next Rho::Daemon::Refusal.malformed("executor_public_id must be a public id or null") if executor == ""

              binding = ctx.host_binding(public_id)
              next Rho::Daemon::Refusal.not_followed(public_id, lane: :host, hint: "attach it first") if binding.nil?

              if executor
                document = discover(client, executor)
                next document if document in Rho::Daemon::Refusal

                ctx.learn_runner(document)
              end
              host = binding.fetch(:host)
              previous = binding[:runner]
              bound = host.context(client.workspace(workspace_public_id)).set_default_runner(executor_public_id: executor)
              ctx.remember(host, workspace: binding.fetch(:workspace), live: binding.fetch(:live), runner: executor)
              ctx.declare_profile
              [200, { host: { type: host.type, public_id: host.public_id }, default_runner: bound.default_runner&.to_h,
                      previous: previous }]
            end
          end

          private

            def row(document, ctx, bindings, selection)
              {
                public_id: document.public_id, display_name: document.display_name,
                presence: document.presence, last_seen_at: document.last_seen_at,
                root: document.environment["root"], tools: document.tool_names,
                own: ctx.own_runner?(document.public_id), selected: document.public_id == selection,
                default_hosts: bindings.select { |binding| binding[:runner] == document.public_id }
                  .map { |binding| binding.fetch(:host).public_id },
              }
            end

            # An ineligible or unknown id is absence on the discovery read —
            # the plane conceals what a principal may not address.
            def discover(client, executor)
              client.executors.show(executor)
            rescue CybrosAgent::Api::NotFound
              Rho::Daemon::Refusal.new(status: 404, code: "runner_not_found",
                message: "#{executor} is not a runner this profile may address; `rho runners` lists them")
            end
        end
      end
    end
  end
end
