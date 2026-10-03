module Rho
  module Extensions
    module Handoff
      # The two doors behind the verbs: the listing, and the handoff. Both
      # reach the kernel through `ctx.member_plane`; the bindings through
      # the facade's store readers; nothing here holds state past one call.
      module Routes
        class << self
          def register(api)
            api.register_route("GET", "/runners") { |_request, ctx| runners(ctx) }
            api.register_route("POST", "/handoff") { |request, ctx| handoff(request, ctx) }
          end

          # THE LISTING: what discovery answers for this profile
          # — the runner kind alone — each with the kernel's presence word
          # (a FOREIGN executor's; this machine's own prints local truth in
          # `rho status`), its announced root and names, and this daemon's
          # marks: own, selected in the settings, bound by which followed
          # hosts, and the first name whose bytes would collide with the
          # union. Every document read refreshes the daemon's cache, and
          # the union is declared if a refreshed announcement moved it.
          def runners(ctx)
            ctx.member_plane(require_workspace: false) do |client, *|
              listed = client.executors.list(kind: "runner")
              listed.each { |document| ctx.learn_runner(document) }
              bindings = ctx.host_bindings
              selection = ctx.settings_runner
              rows = listed.map { |document| row(document, ctx, bindings, selection) }
              ctx.declare_union
              [200, { runners: rows, selection: selection }]
            end
          end

          # THE VERB: a host this daemon follows, resolved as
          # `say` resolves (the host's own id or its backing loop's); the
          # target read from discovery (an id it does not list is
          # `runner_not_found`); the collision check BEFORE the bind — a
          # target announcing a name this rho or a unioned runner declares
          # in other bytes is refused, because the model would be offered
          # two readings of one name; then the bind through the SDK on the
          # host's own door (the kernel's `runner_not_eligible` and its 403
          # cross as themselves), the row's binding moved, the union
          # declared if it moved. The answer carries the kernel's `runner:`
          # read, the binding the row held before, and — when the old
          # binding's and the target's announced trees differ
          # — ONE `warning` sentence naming the fields; never a refusal.
          def handoff(request, ctx)
            ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
              public_id = body["public_id"].to_s
              next Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

              executor = body["executor_public_id"].to_s
              next Rho::Daemon::Refusal.malformed("executor_public_id is required") if executor.empty?

              binding = ctx.host_binding(public_id)
              next Rho::Daemon::Refusal.not_followed(public_id, lane: :host, hint: "attach it first") if binding.nil?

              document = discover(client, executor)
              next document if document in Rho::Daemon::Refusal

              ctx.learn_runner(document)
              conflict = ctx.declaration_conflicts(document).first
              next conflict_refusal(conflict, executor) if conflict

              host = binding.fetch(:host)
              previous = binding[:runner]
              bound = host.context(client.workspace(workspace_public_id)).bind_runner(executor_public_id: executor)
              ctx.remember(host, workspace: binding.fetch(:workspace), live: binding.fetch(:live), runner: executor)
              ctx.declare_union
              relayed = relay_record(ctx, host, executor, document, client, workspace_public_id)
              [200, { host: { type: host.type, public_id: host.public_id }, runner: bound.runner&.to_h,
                      previous: previous, warning: tree_warning(ctx, client, previous, document),
                      environment: relayed }.compact]
            end
          end

          private

            # THE RECORD FOLLOWS THE HANDOFF:
            # a conversation's environment record is the conversation's
            # row, so right after the bind the new runner is told it —
            # the document the verb just read handed in, never fetched
            # twice; this machine's own runner needs no telling, and a
            # row with no record has nothing to relay.
            def relay_record(ctx, host, executor, document, client, workspace_public_id)
              return nil unless host.outlives_turn? && !ctx.own_runner?(executor)

              plane = MemberPlane.new(client: client, workspace_public_id: workspace_public_id)
              binding = ctx.environments.binding_for(host.public_id, plane: plane)
              return nil if binding.nil?

              { relayed: ctx.environments.assert_remote(host.public_id, executor, binding, plane: plane, document: document).to_h }
            end

            def row(document, ctx, bindings, selection)
              {
                public_id: document.public_id, display_name: document.display_name,
                presence: document.presence, last_seen_at: document.last_seen_at,
                root: document.environment["root"], tools: document.tool_names,
                own: ctx.own_runner?(document.public_id), selected: document.public_id == selection,
                bound_hosts: bindings.select { |binding| binding[:runner] == document.public_id }
                  .map { |binding| binding.fetch(:host).public_id },
                conflict: ctx.declaration_conflicts(document).first,
              }
            end

            # The old binding as discovery shows it NOW — read fresh, the way the target is, never
            # the cache: a runner re-announces its tree on every repoint (this home's own on `rho do
            # --dir`, one elsewhere on its own), and the document as it was LAST read warned "not
            # synced" across two homes standing at one root. The cache learns the read. A row that
            # knew none, or a runner discovery no longer lists, has no tree to compare.
            def tree_warning(ctx, client, previous, target)
              return nil if previous.nil?

              document = discover(client, previous)
              return nil if document in Rho::Daemon::Refusal

              ctx.learn_runner(document)
              TreeSync.warning(old: document, new: target)
            end

            # An ineligible or unknown id is absence on the discovery read —
            # the plane conceals what a principal may not address.
            def discover(client, executor)
              client.executors.show(executor)
            rescue CybrosAgent::Api::NotFound
              Rho::Daemon::Refusal.new(status: 404, code: "runner_not_found",
                message: "#{executor} is not a runner this profile may address; `rho runners` lists them")
            end

            def conflict_refusal(name, executor)
              Rho::Daemon::Refusal.new(status: 409, code: "declaration_conflict",
                message: "#{name} is declared with different bytes by this rho and by #{executor}; " \
                         "a handoff would offer the model two readings of one name")
            end
        end
      end
    end
  end
end
