module Rho
  module Extensions
    module Ops
      # Durable conversations in the adopted workspace, independent of the
      # daemon's followed hosts. Nexus owns their visibility and lifecycle.
      module Conversations
        def self.register(api)
          api.register_route("GET", "/conversations") { |request, ctx| list(request, ctx) }
          api.register_route("GET", "/conversations/links") { |request, ctx| links(request, ctx) }
          api.register_route("POST", "/conversations/links/close") { |request, ctx| close_link(request, ctx) }
          api.register_route("GET", "/conversations/detail") { |request, ctx| detail(request, ctx) }
          api.register_route("GET", "/conversations/artifacts") { |request, ctx| artifacts(request, ctx) }
          api.register_route("GET", "/conversations/modes") { |request, ctx| ctx.conversation_modes(request) }
          api.register_route("PATCH", "/conversations/modes") { |request, ctx| ctx.conversation_modes(request, write: true) }
          api.register_route("POST", "/conversations/prepare-input-policy") { |request, ctx| prepare_input_policy(request, ctx) }
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
            fields[:answering_user_public_id] = ctx.own_user_public_id if query["scope"] == "main"
            page = query["archived"] == "1" ? conversations.archived(**fields) : conversations.list(**fields)
            [200, { conversations: page.items.map { |row| summary(row, ctx) }, pagination: { next_after: page.next_after } }]
          end
        end

        # Every projection names the ingress channels holding the conversation
        # (`ingresses`, empty when none), read from each ingress's live route
        # state at answer time: the sidebar marks a bound row before anyone
        # opens it, and the open page's notice reads the same fact.
        def self.summary(row, ctx)
          row.to_h.merge(parent: row.parent&.to_h, ingresses: ctx.conversation_bindings(row.public_id)).compact
        end

        def self.links(request, ctx)
          query = ControlServer.query(request)
          public_id = query["public_id"].to_s
          return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

          ctx.member_plane(request) do |client, workspace_public_id|
            page = client.workspace(workspace_public_id).conversation(public_id).links.list(state: "active", after: query["after"])
            [200, { links: page.items.map { |link| link.to_h.merge(endpoint: link.endpoint.to_h, peer: link.peer.to_h) },
                    pagination: { next_after: page.next_after } }]
          end
        end

        def self.close_link(request, ctx)
          command(request, ctx) do |conversation, body|
            public_id = body["link_public_id"].to_s
            next Rho::Daemon::Refusal.malformed("link_public_id is required") if public_id.empty?

            link = conversation.links.close(public_id)
            [200, { link: link.to_h.merge(endpoint: link.endpoint.to_h, peer: link.peer.to_h) }]
          end
        end

        def self.detail(request, ctx)
          public_id = ControlServer.query(request)["public_id"].to_s
          return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

          ctx.member_plane(request) do |client, workspace_public_id|
            row = client.workspace(workspace_public_id).conversation(public_id).fetch
            [200, { conversation: document(row, ctx).merge(workspace_public_id: workspace_public_id) }]
          end
        end

        def self.document(row, ctx)
          context = row.context
          summary(row, ctx).merge(
            bot_public_id: row.metadata[BotSettings::CONVERSATION_METADATA_KEY],
            input_queue: row.input_queue.to_h,
            context: context && context.to_h.merge(as_of_model: context.as_of_model&.to_h).compact,
            usage_summary: row.usage_summary.to_h,
            cost_limit: row.cost_limit,
            default_runner: row.default_runner&.to_h,
            access: { default: row.access.default, entries: row.access.entries.map(&:to_h) }
          )
        end

        def self.artifacts(request, ctx)
          query = ControlServer.query(request)
          public_id, turn_id, variant_id = %w[public_id turn variant].map { |name| query[name].to_s }
          return Rho::Daemon::Refusal.malformed("public_id, turn and variant are required") if [public_id, turn_id, variant_id].any?(&:empty?)

          ctx.member_plane(request) do |client, workspace_public_id|
            workspace = client.workspace(workspace_public_id)
            turn = workspace.conversation(public_id).turns.fetch(turn_id)
            variant = turn.active_variant
            unless variant&.public_id == variant_id
              next Rho::Daemon::Refusal.new(status: 409, code: "stale_variant", message: "The displayed answer has changed")
            end

            files = if !turn.reference? && !turn.compaction_summary? && variant.status == "completed" && !variant.details_pruned_at
              PublishedArtifacts.new(workspace).collect(run_public_id: variant.run_public_id, results: turn.callback_sources.map(&:result))
            else
              []
            end
            [200, { published_artifacts: files.map(&:to_h) }]
          end
        end

        def self.prepare_input_policy(request, ctx)
          body = ControlServer.json_body(request)
          fields = %w[workspace_public_id public_id]
          unknown = body.keys - fields
          return Daemon::Refusal.malformed("unknown fields: #{unknown.join(", ")}") unless unknown.empty?
          missing = fields.find { |key| String.try_convert(body[key]).to_s.strip.empty? }
          return Daemon::Refusal.parameter_missing(missing) if missing

          public_id = body.fetch("public_id")
          ctx.member_plane(workspace_public_id: body.fetch("workspace_public_id")) do |client, workspace_public_id|
            workspace = client.workspace(workspace_public_id)
            document = workspace.conversation(public_id).fetch
            if document.side? || document.archived?
              next Daemon::Refusal.new(status: 409, code: "input_policy_unavailable",
                message: "Input policy preparation requires an active, non-side conversation")
            end
            if document.metadata[BotSettings::CONVERSATION_METADATA_KEY] || ctx.conversation_bindings(public_id).any?
              next Daemon::Refusal.new(status: 409, code: "ingress_bound", message: "Continue this conversation in its channel")
            end

            policy = ctx.conversation_tool_names(public_id, workspace, client: client, document: document, include_contexts: true)
            next policy if policy in Daemon::Refusal
            # The shared selector passes foreign answerers through for schedules.
            # A prepared Human input needs an explicit allowlist, including an empty one.
            if policy.fetch(:tool_names).nil?
              next Daemon::Refusal.new(status: 409, code: "input_policy_unavailable", message: "The answerer belongs to another agent")
            end

            [200, policy]
          end
        end

        def self.update(request, ctx)
          command(request, ctx) do |conversation, body|
            fields = body.slice("title", "cost_limit").transform_keys(&:to_sym)
            next Rho::Daemon::Refusal.malformed("title or cost_limit is required") if fields.empty?

            current = conversation.fetch
            [200, { conversation: document(conversation.update(**fields, lock_version: current.lock_version), ctx) }]
          end
        end

        def self.archive(request, ctx)
          command(request, ctx) { |conversation| [200, { conversation: document(conversation.archive, ctx) }] }
        end

        def self.unarchive(request, ctx)
          command(request, ctx) { |conversation| [200, { conversation: document(conversation.unarchive, ctx) }] }
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
