module Rho
  module Extensions
    module Ops
      # `rho skills`' ROW HALF: the
      # kernel's `skills/` rows on the two rungs a skill may take, each
      # through the memory door that owns it — the person's own
      # (`profile/memory`, the `user/` rung, reachable from any workspace)
      # and the room's own (`workspaces/{id}/memory`, the `workspace/` rung of this daemon's adopted workspace). Each door lists its one scope,
      # so a listing is filtered to `skills/` alone. The PROJECT section is
      # what this daemon's runner announces under `documents` — the root's
      # skills, as the Coding extension scans them (the same bytes
      # `announce_tools` sends) — never a row, and `null` while no root is
      # set. NOT the merge: the merge is the kernel's, read as the seed's
      # bytes through `rho request`.
      #
      # The kernel judges every write: its four skill words
      # (`skill_description_required`, `memory_description_invalid`,
      # `skill_name_invalid`, `skill_scope_unavailable`) call_tool as the 422s
      # they are, through the route table's one exception map.
      module SkillRoutes
        WORKSPACE_PREFIX = "workspace/skills/".freeze
        USER_PREFIX = "user/skills/".freeze
        SCOPES = %w[user workspace].freeze

        class << self
          def register(api)
            api.register_route("GET", "/skills") { |request, ctx| list(request, ctx) }
            api.register_route("POST", "/skills/push") { |request, ctx| push(request, ctx) }
            api.register_route("GET", "/skills/show") { |request, ctx| show(request, ctx) }
            api.register_route("POST", "/skills/rm") { |request, ctx| remove(request, ctx) }
          end

          # Three sections: the person's rung whole, the adopted workspace's
          # rung whole, and the project's — this runner's announced documents.
          def list(_request, ctx)
            ctx.member_plane do |client, workspace_public_id|
              user = client.profile.memory.list.select { |row| row.path.start_with?(USER_PREFIX) }
              workspace = client.workspace(workspace_public_id).memory.list
                .select { |row| row.path.start_with?(WORKSPACE_PREFIX) }
              [200, { skills: { user: user.map { |row| skill_row(row) },
                                workspace: workspace.map { |row| skill_row(row) },
                                project: project_documents(ctx) } }]
            end
          end

          # THE SPLIT ALREADY DONE by the CLI (`Rho::Runner::Skills`, the
          # runner's own parser — the file is where the person's terminal
          # is): the body carries the row's three fields and the rung.
          def push(request, ctx)
            ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
              scope = body["scope"].to_s
              next Rho::Daemon::Refusal.malformed("scope must be user or workspace") unless SCOPES.include?(scope)

              name = body["name"].to_s
              next Rho::Daemon::Refusal.malformed("name is required") if name.empty?
              content = String.try_convert(body["content"])
              next Rho::Daemon::Refusal.malformed("content must be a string") if content.nil?

              written = memory_door(client, workspace_public_id, scope).write("#{scope}/skills/#{name}", content,
                description: body["description"], expected_public_id: body.fetch("expected_public_id"),
                expected_lock_version: body.fetch("expected_lock_version"))
              [201, { memory: written.to_h }]
            end
          rescue KeyError => error
            Rho::Daemon::Refusal.parameter_missing(error.key)
          end

          def show(request, ctx)
            query = ControlServer.query(request)
            scope, name = query.values_at("scope", "name").map(&:to_s)
            return Rho::Daemon::Refusal.malformed("scope must be user or workspace") unless SCOPES.include?(scope)
            return Rho::Daemon::Refusal.malformed("name is required") if name.empty?

            ctx.member_plane do |client, workspace_public_id|
              [200, { memory: memory_door(client, workspace_public_id, scope).read("#{scope}/skills/#{name}").to_h }]
            end
          end

          def remove(request, ctx)
            ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
              scope, name = body.values_at("scope", "name").map(&:to_s)
              next Rho::Daemon::Refusal.malformed("scope must be user or workspace") unless SCOPES.include?(scope)
              next Rho::Daemon::Refusal.malformed("name is required") if name.empty?

              path = "#{scope}/skills/#{name}"
              memory_door(client, workspace_public_id, scope).delete(path,
                expected_public_id: body.fetch("expected_public_id"), expected_lock_version: body.fetch("expected_lock_version"))
              [200, { deleted: { path: path } }]
            end
          rescue KeyError => error
            Rho::Daemon::Refusal.parameter_missing(error.key)
          end

          private

            # The door a rung is reached through: the profile's for `user/`,
            # the adopted workspace's own for `workspace/`.
            def memory_door(client, workspace_public_id, scope)
              scope == "user" ? client.profile.memory : client.workspace(workspace_public_id).memory
            end

            # What the runner address announces for the root of the moment:
            # the registry's runner projection over the root's environment —
            # `RunDeclaration.documents`, the announcement's own reader — or
            # nil while no root is set (nothing is announced from nowhere).
            def project_documents(ctx)
              root = ctx.environment.root
              return nil if root.nil?

              RunDeclaration.documents(registry: ctx.registry.serving(:runner),
                environment: Rho::Runner::Environment.local(root: root))
            end

            def skill_row(row)
              { name: row.path.split("/skills/", 2).last, path: row.path, public_id: row.public_id,
                lock_version: row.lock_version, description: row.description,
                bytesize: row.bytesize, written_at: row.written_at }
            end
        end
      end
    end
  end
end
