module Rho
  module Extensions
    module Ops
      # The CLI edits the Agent and Workspace default collections. It discovers
      # their metadata, then addresses documents by UUID and relative path.
      # Project skills remain the Runner's independently announced documents.
      module SkillRoutes
        PREFIX = "skills/".freeze
        SCOPES = %w[agent workspace].freeze

        class << self
          def register(api)
            api.register_route("GET", "/skills") { |request, ctx| list(request, ctx) }
            api.register_route("POST", "/skills/push") { |request, ctx| push(request, ctx) }
            api.register_route("GET", "/skills/show") { |request, ctx| show(request, ctx) }
            api.register_route("POST", "/skills/rm") { |request, ctx| remove(request, ctx) }
          end

          def list(_request, ctx)
            ctx.member_plane do |client, workspace_public_id|
              collections = SCOPES.to_h { |scope| [scope, default_collection(client, workspace_public_id, scope)] }
              documents = collections.transform_values do |collection|
                collection ? client.memory_collections.documents(collection.public_id).list.select { |row| row.path.start_with?(PREFIX) } : []
              end
              [200, { skills: { agent: documents.fetch("agent").map { |row| skill_row(row) },
                workspace: documents.fetch("workspace").map { |row| skill_row(row) },
                collections: collections.transform_values { |row| row&.to_h }, project: project_documents(ctx) } }]
            end
          end

          # THE SPLIT ALREADY DONE by the CLI (`Rho::Runner::Skills`, the
          # runner's own parser — the file is where the person's terminal
          # is): the body carries the row's three fields and the rung.
          def push(request, ctx)
            ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
              scope = body["scope"].to_s
              next Rho::Daemon::Refusal.malformed("scope must be agent or workspace") unless SCOPES.include?(scope)

              name = body["name"].to_s
              next Rho::Daemon::Refusal.malformed("name is required") if name.empty?
              content = String.try_convert(body["content"])
              next Rho::Daemon::Refusal.malformed("content must be a string") if content.nil?

              written = memory_door(client, workspace_public_id, scope, expected: body.fetch("expected_collection_public_id").to_s).write("skills/#{name}", content,
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
            return Rho::Daemon::Refusal.malformed("scope must be agent or workspace") unless SCOPES.include?(scope)
            return Rho::Daemon::Refusal.malformed("name is required") if name.empty?

            ctx.member_plane do |client, workspace_public_id|
              [200, { memory: memory_door(client, workspace_public_id, scope).read("skills/#{name}").to_h }]
            end
          end

          def remove(request, ctx)
            ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
              scope, name = body.values_at("scope", "name").map(&:to_s)
              next Rho::Daemon::Refusal.malformed("scope must be agent or workspace") unless SCOPES.include?(scope)
              next Rho::Daemon::Refusal.malformed("name is required") if name.empty?

              path = "skills/#{name}"
              memory_door(client, workspace_public_id, scope, expected: body.fetch("expected_collection_public_id").to_s).delete(path,
                expected_public_id: body.fetch("expected_public_id"), expected_lock_version: body.fetch("expected_lock_version"))
              [200, { deleted: { path: path } }]
            end
          rescue KeyError => error
            Rho::Daemon::Refusal.parameter_missing(error.key)
          end

          private

            def default_collection(client, workspace_public_id, scope)
              owner = scope == "agent" ? client.profile : client.workspace(workspace_public_id)
              owner.memory_collections.list(default: true).items.first
            end

            def memory_door(client, workspace_public_id, scope, expected: nil)
              collection = default_collection(client, workspace_public_id, scope)
              raise CybrosAgent::Api::InvalidRequest.new("The default collection is unavailable", code: "memory_scope_unavailable") unless collection
              if expected && collection.public_id != expected
                raise CybrosAgent::Api::Conflict.new("The selected collection changed", code: "stale_object")
              end

              client.memory_collections.documents(collection.public_id)
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
              { name: row.path.delete_prefix(PREFIX), collection_public_id: row.collection_public_id, path: row.path, public_id: row.public_id,
                lock_version: row.lock_version, description: row.description,
                bytesize: row.bytesize, written_at: row.written_at }
            end
        end
      end
    end
  end
end
