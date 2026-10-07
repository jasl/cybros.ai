module Rho
  module Extensions
    module Ops
      # Shared history doors for the CLI, browser and external chat surfaces.
      # Nexus owns search visibility, tail-only mutation and lineage overlays.
      module ConversationHistory
        def self.register(api)
          api.register_route("GET", "/conversations/search") { |request, ctx| search(request, ctx) }
          api.register_route("GET", "/conversations/history") { |request, ctx| history(request, ctx) }
          api.register_route("POST", "/conversations/turns/edit") { |request, ctx| edit(request, ctx) }
          api.register_route("POST", "/conversations/turns/delete") { |request, ctx| delete(request, ctx) }
          api.register_route("POST", "/conversations/turns/view") { |request, ctx| view(request, ctx) }
        end

        def self.search(request, ctx)
          query = ControlServer.query(request)
          ctx.member_plane(request) do |client, workspace_id|
            page = client.workspace(workspace_id).conversations.search(query: query.fetch("query", ""),
              after: query["after"], limit: query["limit"], archived: query["archived"])
            [200, { matches: page.matches.map(&:to_h), pagination: { next_after: page.next_after } }]
          end
        end

        def self.history(request, ctx)
          query = ControlServer.query(request)
          id = query.fetch("public_id", "")
          return Rho::Daemon::Refusal.malformed("public_id is required") if id.empty?

          ctx.member_plane(request) do |client, workspace_id|
            page = client.workspace(workspace_id).conversation(id).history.list(
              before_position: query["before_position"], after_position: query["after_position"], limit: query["limit"])
            [200, { conversation: page.conversation.to_h, turns: page.turns.map(&:to_h), truncated: page.truncated,
              pagination: { before_position: page.before_position, after_position: page.after_position,
                has_older: page.has_older, has_newer: page.has_newer } }]
          end
        end

        def self.edit(request, ctx)
          command(request, ctx) do |turns, turn, body|
            next Rho::Daemon::Refusal.malformed("text is required") unless body.key?("text")

            [200, { variant: turns.edit(turn, text: body.fetch("text")).to_h }]
          end
        end

        def self.delete(request, ctx)
          command(request, ctx) do |turns, turn|
            turns.delete(turn)
            [200, { deleted: { public_id: turn } }]
          end
        end

        def self.view(request, ctx)
          command(request, ctx) do |turns, turn, body|
            fields = body.slice("visibility", "concealed").transform_keys(&:to_sym)
            next Rho::Daemon::Refusal.malformed("visibility or concealed is required") if fields.empty?

            [200, { turn: turns.set_view_state(turn, **fields).to_h }]
          end
        end

        def self.command(request, ctx)
          ctx.member_plane(request, body: true) do |client, workspace_id, _about, body|
            id, turn = body.fetch("public_id", "").to_s, body.fetch("turn", "").to_s
            next Rho::Daemon::Refusal.malformed("public_id and turn are required") if id.empty? || turn.empty?

            yield client.workspace(workspace_id).conversation(id).turns, turn, body
          end
        end
      end
    end
  end
end
