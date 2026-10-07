module Conversations
  module Turns
    # THE SEAM'S ONE WRITER: a kernel loop born behind a loop-backed
    # variant — its event cursor, its seed through the one append door, the
    # seed's input body when the caller seals one, and the loop born
    # running. No driving row starts it: the turn is the start. Three
    # callers, one writer — the drain's loop-backed reply
    # (`Inputs::ApplyNext`), the compaction arm's one-task summary loop
    # (`Compaction::Arm`), and regeneration (`Turns::Regenerate`, a fresh
    # loop behind a new variant).
    module BackingRun
      module_function

      # Answers the loop, or the append's / the body's refusal as an
      # Outcome. `seed_body` is round one's assembled request, sealed onto
      # the first step by its key; a step with a prompt of its own needs
      # none. `prompt_mechanism` is the turn's: `raw` when the input was
      # sent verbatim, `default` for the assembler's order, nil for the
      # kernel's own summary loop (neither mechanism). `approval_mode` and
      # `approval_rules` are the turn's FREEZE: the input's tightening,
      # else the declaring profile's word, and the profile's rule list —
      # required, never defaulted. A summary without lifecycle hooks has
      # no tools to approve and names `bypass`. `seed_uploads` are the rows the seed places
      # natively: the seed binds them so round one's composition finds them
      # by its joins; a composed request, never bounded as a person's
      # message. `seed_source` is the OTHER spelling of the seed's body: a
      # SEALED body — an earlier loop's seed input — identity-copied onto
      # the new seed node, pointer rows onto the same fragments and
      # uploads, zero content bytes, nothing re-proven. One of the two.
      def create(conversation:, variant:, creating_user:, steps:, tip:, approval_mode:, approval_rules:,
                 seed_body: nil, seed_uploads: [], seed_source: nil, prompt_mechanism: nil,
                 authored_steps: nil, append_key: nil,
                 lifecycle_hooks: variant.conversation_turn.answering_user.lifecycle_hooks,
                 memory_context: conversation.memory_context)
        raise ArgumentError, "seed_body and seed_source are two spellings of one seed" if seed_body && seed_source

        variant.update!(memory_context: memory_context) unless variant.memory_context == memory_context
        agent_run = AgentRun.create!(
          workspace: conversation.workspace,
          creating_user: creating_user,
          conversation_turn_variant: variant,
          prompt_mechanism: prompt_mechanism,
          approval_mode: approval_mode,
          approval_rules: approval_rules.presence,
          lifecycle_hooks: lifecycle_hooks,
          billing_subject_key: conversation.billing_subject_key,
          billing_subject_public_id: conversation.billing_subject_public_id,
        )
        agent_run.create_conversation_event_cursor!(account: agent_run.account)
        seeded = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
          agent_run: agent_run, steps: steps, tip: tip, origin: "kernel"
        ))
        return Outcome.refused(seeded.outcome) unless seeded.applied?

        if authored_steps.present?
          # The seed append already holds this newborn Run in the caller's
          # transaction. Accept authored work before sealing the seed body:
          # attachment resolution must precede ContentFragment locks. The
          # caller rolls back the whole candidate on any refusal.
          appended = AgentRuns::Tasks::Append.call_locked(AgentRuns::Tasks::Append::Command.authored(
            agent_run: agent_run, steps: authored_steps, idempotency_key: append_key, creator: creating_user
          ))
          return Outcome.refused(appended.outcome) unless appended.applied?
        end

        if seed_source
          ContentBodies::CloneSealed.call(
            source: seed_source, owner: agent_run.agent_run_tasks.find_by!(node_key: steps.first.key),
            role: "input"
          )
        elsif seed_body
          request = ContentBodies::Replace.call(
            owner: agent_run.agent_run_tasks.find_by!(node_key: steps.first.key), role: "input",
            entries: Nexus::InputEntries.for(seed_body),
            uploads: seed_uploads, composed: true,
            seal: true
          )
          return Outcome.refused(request.refusal) unless request.accepted?
        end

        AgentRuns::Transition.agent_run(agent_run, status: "running", started_at: Time.current)
        Outcome.accepted(agent_run)
      end
    end
  end
end
