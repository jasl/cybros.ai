module Schedules
  module Execution
    module_function

    # The exact accepted occurrence owns this check. A later exchange or
    # manual regeneration in its reusable child cannot hold the clock.
    def unfinished?(child)
      return false unless child

      child.with_lock do
        next true if child.conversation_inputs.exists?(public_id: child.scheduled_input_public_id)

        turn = child.conversation_turns.find_by(public_id: child.scheduled_turn_public_id)
        variant = AgentRuns::Delegations.answering_variant(turn)
        loop = variant&.agent_run
        variant.present? && (!variant.terminal? || (loop && !loop.terminal?))
      end
    end

    def ready_for_reply?(turn)
      turn.conversation.with_lock do
        variant = AgentRuns::Delegations.answering_variant(turn.reload)
        loop = variant&.agent_run
        if loop
          # The child lock orders edits before this execution lock. A held
          # original hidden by an edit can no longer be repaired and must drain.
          loop.with_lock do
            AgentRuns::Stop.stop_now(loop) if loop.needs_attention? && loop.overridden?
          end
        end
        # A repairable hold projects a failed sample without ending its execution.
        variant&.terminal? && (!loop || loop.delivered? || loop.terminal?)
      end
    end
  end
end
