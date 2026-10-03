module Rho
  module Extensions
    module Ops
      # Durable conversations in the adopted workspace, independent of the
      # daemon's followed hosts. Nexus owns their visibility and lifecycle.
      module Conversations
        def self.register(api)
          api.register_route("GET", "/conversations") { |request, ctx| list(request, ctx) }
          api.register_route("GET", "/conversations/detail") { |request, ctx| detail(request, ctx) }
          api.register_route("PATCH", "/conversations") { |request, ctx| update(request, ctx) }
          api.register_route("POST", "/conversations/archive") { |request, ctx| archive(request, ctx) }
          api.register_route("POST", "/conversations/unarchive") { |request, ctx| unarchive(request, ctx) }
        end

        def self.list(request, ctx)
          query = ControlServer.query(request)
          limit = Integer(query["limit"], exception: false) if query["limit"]
          return Rho::Daemon::Refusal.malformed("limit must be a positive integer") if query["limit"] && !limit&.positive?

          ctx.member_plane(request) do |client, workspace_public_id|
            conversations = client.workspace(workspace_public_id).conversations
            fields = { after: query["after"], limit: limit }
            page = query["archived"] == "1" ? conversations.archived(**fields) : conversations.list(**fields)
            [200, { conversations: page.items.map { |row| summary(row) }, pagination: { next_after: page.next_after } }]
          end
        end

        def self.summary(row)
          row.to_h.merge(parent: row.parent&.to_h).compact
        end

        def self.detail(request, ctx)
          public_id = ControlServer.query(request)["public_id"].to_s
          return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

          ctx.member_plane(request) do |client, workspace_public_id|
            row = client.workspace(workspace_public_id).conversation(public_id).fetch
            [200, { conversation: document(row).merge(workspace_public_id: workspace_public_id,
              ingresses: ctx.conversation_bindings(public_id)) }]
          end
        end

        def self.document(row)
          context = row.context
          summary(row).merge(
            input_queue: row.input_queue.to_h,
            context: context && context.to_h.merge(as_of_model: context.as_of_model&.to_h).compact,
            runner: row.runner&.to_h,
            access: { default: row.access.default, entries: row.access.entries.map(&:to_h) }
          )
        end

        def self.update(request, ctx)
          command(request, ctx) do |conversation, body|
            next Rho::Daemon::Refusal.malformed("title is required") unless body.key?("title")

            [200, { conversation: document(conversation.update(title: body["title"])) }]
          end
        end

        def self.archive(request, ctx)
          command(request, ctx) { |conversation| [200, { conversation: document(conversation.archive) }] }
        end

        def self.unarchive(request, ctx)
          command(request, ctx) { |conversation| [200, { conversation: document(conversation.unarchive) }] }
        end

        def self.command(request, ctx)
          ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
            public_id = body["public_id"].to_s
            next Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

            yield client.workspace(workspace_public_id).conversation(public_id), body
          end
        end
      end
    end
  end
end
