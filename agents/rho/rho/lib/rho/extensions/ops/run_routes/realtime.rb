module Rho
  module Extensions
    module Ops
      module RunRoutes
        class << self
          # Only signaling crosses the daemon. Terminal bytes remain on the
          # task's direct/TURN channel, under the existing member authority.
          def task_realtime(request, ctx, answer: false)
            task_command(request, ctx, body: answer) do |task, fields|
              projection = if answer
                task.answer_realtime(connection_id: fields.fetch("connection_id"), sdp: fields.fetch("sdp"))
              else
                task.realtime
              end
              Protocol::HTTP::Response[200,
                { "content-type" => ControlServer::JSON_TYPE, "cache-control" => "no-store", "x-content-type-options" => "nosniff" },
                [JSON.generate(realtime: projection.to_h)]]
            end
          end

          def task_cancel(request, ctx)
            task_command(request, ctx, body: true) do |task, _fields|
              [200, { task: task.cancel.to_h }]
            end
          end

          private

            def task_command(request, ctx, body:)
              fields = body ? ControlServer.json_body(request) : ControlServer.query(request)
              public_id = fields["public_id"].to_s
              task_key = fields["task_key"].to_s
              return Rho::Daemon::Refusal.malformed("public_id and task_key are required") if public_id.empty? || task_key.empty?

              ctx.member_plane(host_public_id: public_id, **fields.slice("workspace_public_id").transform_keys(&:to_sym)) do |client, workspace_public_id|
                task = ctx.runs_for(client, workspace_public_id).run(public_id).tasks_context(task_key)
                yield task, fields
              end
            end
        end
      end
    end
  end
end
