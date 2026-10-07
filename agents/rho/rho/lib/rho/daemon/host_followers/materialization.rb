module Rho
  class Daemon
    class HostFollowers
      module Materialization
        private

          def input_receipt(accepted, position)
            { public_id: accepted.public_id, state: accepted.state,
              deliver_at: accepted.input.deliver_at, position: position.to_h }.compact
          end

          # The exact input owns the answer. A follower's latest turn is
          # useful progress, but another sender may have opened it.
          def await_materialization(hosted, accepted, position)
            reader = CybrosAgent::InputMaterialization.new(input_public_id: accepted.public_id, position: position,
              replay: ->(cursor) { hosted.events(after: cursor) },
              recover: ->(input) {
                CybrosAgent::InputMaterialization::Result.from_materialization(
                  hosted.inputs.materialization(input, include_hidden: true))
              })
            deadline = @clock.call + MATERIALIZATION_WAIT
            loop do
              reader.refresh
              return [:materialized, reader.result] if reader.result
              return [:blocked, reader.blocked_reason] if reader.blocked_reason
              return (reader.compaction && [:compaction, reader.compaction]) if @clock.call >= deadline

              @sleeper.call(MATERIALIZATION_POLL)
            end
          end

          # Scheduled, steering and already-busy inputs remain immediate
          # pending receipts; their surfaces can continue from the same
          # pre-POST position. Only an idle conversation waits here.
          def turn_answer(hosted, accepted, position, in_flight:)
            return { pending: true, blocked: accepted.input.blocked_reason }.compact if accepted.state == "blocked"
            return { pending: true } if accepted.state != "pending" || !accepted.input.deliver_at.nil? || in_flight

            outcome, value = await_materialization(hosted, accepted, position)
            return { pending: true, blocked: value } if outcome == :blocked

            materialized_answer(outcome, value)
          end

          def materialized_answer(outcome, value)
            case outcome
            when :materialized then materialized_ids(value)
            when :compaction then { pending: true, compaction: materialized_ids(value) }
            else { pending: true }
            end
          end

          def materialized_ids(value)
            { turn: ( { public_id: value.turn } if value.turn),
              variant: ( { public_id: value.variant } if value.variant),
              run: ( { public_id: value.run_public_id } if value.run_public_id) }.compact
          end

          def turn_in_flight?(run)
            snapshot = run&.snapshot
            !snapshot.nil? && !snapshot.turn.nil? && !snapshot.complete
          end
      end
    end
  end
end
