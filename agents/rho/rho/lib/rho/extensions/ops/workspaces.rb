module Rho
  module Extensions
    module Ops
      module Workspaces
        def self.register(api)
          api.register_route("GET", "/workspaces") { |_request, ctx| list(ctx) }
          api.register_route("GET", "/workspaces/detail") { |request, ctx| detail(request, ctx) }
          api.register_route("POST", "/workspaces") { |request, ctx| create(request, ctx) }
          api.register_route("POST", "/workspaces/select") { |request, ctx| select(request, ctx) }
          api.register_command("workspaces",
            usage: "workspaces | workspaces list | workspaces create NAME | workspaces use ID",
            description: "List, create or choose the workspace for new conversations",
            options: { json: { type: :boolean, default: false, desc: "Print JSON" } }, &method(:command))
        end

        def self.list(ctx)
          ctx.member_plane(require_workspace: false) do |client, workspace_public_id|
            selection = ctx.config.workspace_selection(ctx.home)
            rows = Rho::Workspaces.list(client)
            selected = selection || workspace_public_id
            [200, { workspaces: rows.map(&:to_h), selection: selection,
                    workspace: rows.find { |row| row.public_id == selected }&.to_h }]
          end
        end

        def self.detail(request, ctx)
          public_id = ControlServer.query(request)["public_id"].to_s
          return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

          ctx.member_plane(require_workspace: false) do |client|
            row = Rho::Workspaces.fetch(client, public_id)
            (row in Rho::Daemon::Refusal) ? row : [200, { workspace: summary(row) }]
          end
        end

        def self.create(request, ctx)
          ctx.member_plane(request, body: true, require_workspace: false) do |client, _workspace, _about, body|
            name = body["name"].to_s
            next Rho::Daemon::Refusal.malformed("name is required") if name.strip.empty?

            row = client.workspaces.create(name: name, idempotency_key: body["idempotency_key"] || SecureRandom.uuid).workspace
            [201, { workspace: summary(row) }]
          end
        end

        # Validation only. The Core client persists the operator's setting.
        def self.select(request, ctx)
          ctx.member_plane(request, body: true, require_workspace: false) do |client, _workspace, _about, body|
            if ctx.config.workspace_override
              next Rho::Daemon::Refusal.new(status: 409, code: "workspace_overridden",
                message: "workspace is fixed by --workspace; remove that override before choosing a default")
            end
            row = Rho::Workspaces.fetch(client, body.fetch("public_id").to_s)
            (row in Rho::Daemon::Refusal) ? row : [200, { workspace: summary(row) }]
          end
        end

        def self.summary(row)
          row.to_h.slice(:public_id, :name, :access_mode, :state, :dedicated, :lock_version)
        end

        def self.command(cli, args, options)
          verb, value = args
          result = case verb
          when nil, "list" then cli.core.workspaces
          when "create"
            raise Rho::Error, "name is required: rho workspaces create NAME" if value.to_s.empty?
            cli.core.create_workspace(name: value)
          when "use"
            raise Rho::Error, "workspace is required: rho workspaces use ID" if value.to_s.empty?
            cli.core.select_workspace(value)
          else
            raise Rho::Error, "use rho workspaces [list | create NAME | use ID]"
          end
          if options[:json]
            cli.out.puts JSON.generate(result)
          elsif result.key?("workspaces")
            Array(result["workspaces"]).each do |row|
              mark = row["public_id"] == result.dig("workspace", "public_id") ? "*" : " "
              cli.out.puts "#{mark} #{row.fetch("public_id")}  #{row.fetch("name")}"
            end
          else
            cli.out.puts "workspace: #{result.fetch("public_id")}  #{result.fetch("name")}"
          end
          result
        end
      end
    end
  end
end
