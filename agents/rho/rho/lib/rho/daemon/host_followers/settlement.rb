require_relative "../../turn_settlement"

module Rho
  class Daemon
    class HostFollowers
      module Settlement
        # A failed held execution uses the same settlement observers as a
        # terminal callback, while its attention remains available to the person.
        def follow_attention(run, _attention, runs, source_run_public_id, hosted:)
          snapshot = run.snapshot
          if snapshot.status == "failed" && snapshot.run_public_id == source_run_public_id && run.host.outlives_turn?
            follow_completed(run, runs, hosted)
          end
        end

        private

          def follow_completed(run, runs, hosted)
            follow_settled_model(run, runs, hosted)
            hooks = @loaded.daemon_hooks.select { |hook| hook.event == :turn_settled }
            return if hooks.empty?

            snapshot = run.snapshot
            return unless %w[completed failed canceled].include?(snapshot.status) && snapshot.turn

            row = follow_row(run, hosted)
            return if row.nil?

            turn = hosted.turns.fetch(snapshot.turn, include_hidden: true)
            variant = turn.active_variant
            return unless turn.kind == "direct_reply" && !turn.inherited? && !turn.reference? && turn.status == snapshot.status &&
              variant&.run_public_id == snapshot.run_public_id

            settlement = TurnSettlement.new(workspace_public_id: row.workspace, conversation_public_id: run.public_id,
              turn_public_id: turn.public_id, run_public_id: variant.run_public_id, status: turn.status,
              model: variant.model && "#{variant.model.provider_id}/#{variant.model.model_ref}", memory_context: variant.memory_context)
            hooks.each { |hook| dispatch_settlement(hook, settlement) }
          rescue CybrosAgent::Error, Rho::StateError => error
            @log.warn("turn_settlement_unread", host: run.public_id, error_class: error.class.name)
          end

          # These are observers of a published outcome. The daemon owns their
          # async lifetime; a slow submission must not delay the host event's
          # delivery. Acquire before scheduling so replacement retains exactly
          # the extension instance that accepted the callback.
          def dispatch_settlement(hook, settlement)
            lease = hook.owner&.acquire
            @context.spawn do
              begin
                hook.handler.call(settlement, @context)
              rescue StandardError => error
                @log.warn("turn_settled_hook_failed", extension: hook.extension, run: settlement.run_public_id,
                  error_class: error.class.name)
              ensure
                lease&.release
              end
            end
          rescue StandardError => error
            lease&.release
            @log.warn("turn_settled_hook_failed", extension: hook.extension, run: settlement.run_public_id,
              error_class: error.class.name)
          end
      end
    end
  end
end
