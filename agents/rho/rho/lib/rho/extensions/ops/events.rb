module Rho
  module Extensions
    module Ops
      # A read of the durable feed, independent of whether a local follower
      # has already consumed these items or has a live socket.
      module Events
        class << self
          def register(api)
            api.register_route("GET", "/runs/events") { |request, ctx| read(request, ctx) }
            api.register_route("GET", "/conversations/input_materialization") { |request, ctx| materialization(request, ctx) }
          end

          def read(request, ctx)
            query = ControlServer.query(request)
            public_id = query["public_id"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

            ctx.member_plane(request) do |client, workspace_public_id|
              host = ctx.host_of(public_id, ctx.runs_for(client, workspace_public_id))
              page = host.context(client.workspace(workspace_public_id)).events(
                after: query["after"], limit: query["limit"]&.to_i
              )
              [200, { events: page.items.map { |event| event_document(event) },
                      pagination: { next_after: page.next_after, watermark: page.watermark } }]
            end
          end

          def materialization(request, ctx)
            query = ControlServer.query(request)
            public_id = query["public_id"].to_s
            input_public_id = query["input_public_id"].to_s
            return Rho::Daemon::Refusal.malformed("public_id and input_public_id are required") if public_id.empty? || input_public_id.empty?

            ctx.member_plane(request) do |client, workspace_public_id|
              value = client.workspace(workspace_public_id).conversation(public_id).inputs
                .materialization(input_public_id, include_hidden: true)
              [200, { materialization: value&.to_h }]
            end
          end

          private

            # The SDK's flattened value is restored to the existing wire
            # envelope; the Core consumes its original decoder unchanged.
            def event_document(event)
              { public_id: event.public_id, sequence: event.sequence, cursor: event.cursor,
                type: event.type, resource: { type: event.resource_type, public_id: event.resource_public_id },
                occurred_at: event.occurred_at, payload: event.payload }
            end
        end
      end
    end
  end
end
