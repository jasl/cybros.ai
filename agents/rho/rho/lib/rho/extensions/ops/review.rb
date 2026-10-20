require_relative "../../run_changes"

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
          public_id, turn_id, variant_id = %w[public_id turn variant].map { |name| query[name].to_s }
          return Rho::Daemon::Refusal.malformed("public_id, turn and variant are required") if [public_id, turn_id, variant_id].any?(&:empty?)

          ctx.member_plane(request) do |client, workspace_public_id|
            workspace = client.workspace(workspace_public_id)
            turn = workspace.conversation(public_id).turns.fetch(turn_id)
            variant = turn.active_variant
            unless variant&.public_id == variant_id
              next Rho::Daemon::Refusal.new(status: 409, code: "stale_variant", message: "The displayed answer has changed")
            end
            reviews = if !turn.reference? && !turn.compaction_summary? &&
                CybrosAgent::Api::TURN_TERMINAL_STATUSES.include?(turn.status) && !variant.details_pruned_at
              RunChanges.new(workspace).collect(variant)
            else
              []
            end
            [200, { reviews: reviews }]
          end
        end

        # The excerpt is user-supplied review context, never a system instruction.
        # The caller adds this text to the ordinary composer and its Input retry owner.
        def feedback(request, ctx)
          body = ControlServer.json_body(request)
          ctx.member_plane(host_public_id: body.fetch("public_id")) do |*|
            fields = body.fetch("comment").to_h.slice("runner", "root", "base", "path", "side", "line", "excerpt", "turn", "variant", "run", "text")
            if fields.values.any? { |value| value.to_s.bytesize > 32_768 } || fields.length != 11 ||
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
