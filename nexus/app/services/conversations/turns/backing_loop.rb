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
    module BackingLoop
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
                 lifecycle_hooks: variant.conversation_turn.answering_user.lifecycle_hooks,
                 memory_context: conversation.memory_context)
        raise ArgumentError, "seed_body and seed_source are two spellings of one seed" if seed_body && seed_source

        variant.update!(memory_context: memory_context) unless variant.memory_context == memory_context
        agent_loop = AgentLoop.create!(
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
        agent_loop.create_conversation_event_cursor!(account: agent_loop.account)
        seeded = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
          agent_loop: agent_loop, steps: steps, tip: tip, origin: "kernel"
        ))
        return Outcome.refused(seeded.outcome) unless seeded.applied?

        if seed_source
          ContentBodies::CloneSealed.call(
            source: seed_source, owner: agent_loop.agent_loop_nodes.find_by!(node_key: steps.first.key),
            role: "input"
          )
        elsif seed_body
          request = ContentBodies::Replace.call(
            owner: agent_loop.agent_loop_nodes.find_by!(node_key: steps.first.key), role: "input",
            entries: Nexus::InputEntries.for(seed_body),
            uploads: seed_uploads, composed: true,
            seal: true
          )
          return Outcome.refused(request.refusal) unless request.accepted?
        end

        AgentLoops::Transition.agent_loop(agent_loop, status: "running", started_at: Time.current)
        Outcome.accepted(agent_loop)
      end
    end
  end
end
