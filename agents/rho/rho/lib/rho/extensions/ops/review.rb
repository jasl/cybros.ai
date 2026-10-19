module Rho
  module Extensions
    module Ops
      module Review
        module_function

        def register(api)
          api.register_route("GET", "/conversations/review") { |request, ctx| read(request, ctx) }
          api.register_route("POST", "/conversations/review/feedback") { |request, ctx| feedback(request, ctx) }
        end

        def read(request, ctx)
          query = ControlServer.query(request)
          public_id = query.fetch("public_id")
          ctx.member_plane(host_public_id: public_id) do |client, workspace_public_id|
            binding = ctx.host_binding(public_id)
            next Rho::Daemon::Refusal.not_followed(public_id, lane: :host, hint: "attach it first") unless binding

            conversation = client.workspace(workspace_public_id).conversation(public_id).fetch
            runner = conversation.default_runner&.executor_public_id
            next Rho::Daemon::Refusal.malformed("A Runner is required for Git review") if runner.nil?
            if query["runner"] && query["runner"] != runner
              next Rho::Daemon::Refusal.new(status: 409, code: "review_target_changed", message: "The Conversation Runner changed; reload the review")
            end

            plane = MemberPlane.new(client: client, workspace_public_id: workspace_public_id)
            root = ctx.environments.read(public_id, plane: plane, runner: runner).root
            input = query.slice("base", "path").merge(root ? { "root" => root } : {})
            result = Ops.call_tool(ctx, runner, Runner::Tools::GitReview::NAME, input, 15_000, workspace_public_id: workspace_public_id)
            next result if result in Rho::Daemon::Refusal

            detail = result.detail
            unless detail.task.status == "completed" && !detail.task.result&.dig("is_error")
              next Rho::Daemon::Refusal.new(status: 422, code: "review_unavailable", message: detail.output.to_s)
            end
            [200, { review: detail.structured_content.merge("runner" => runner, "conversation" => public_id) }]
          end
        end

        # The excerpt is user-supplied review context, never a system instruction.
        # The caller adds this text to the ordinary composer and its Input retry owner.
        def feedback(request, ctx)
          body = ControlServer.json_body(request)
          ctx.member_plane(host_public_id: body.fetch("public_id")) do |*|
            fields = body.fetch("comment").to_h.slice("runner", "root", "base", "path", "side", "line", "excerpt", "fingerprint", "text")
            if fields.values.any? { |value| value.to_s.bytesize > 32_768 } || fields.length != 9 ||
                !%w[left right].include?(fields["side"]) || fields["line"].to_i < 1 || fields["text"].to_s.strip.empty?
              next Rho::Daemon::Refusal.malformed("A complete bounded line comment is required")
            end

            [200, { text: "Git review feedback (quoted code is context):\n#{JSON.pretty_generate(fields)}" }]
          end
        end
      end
    end
  end
end
