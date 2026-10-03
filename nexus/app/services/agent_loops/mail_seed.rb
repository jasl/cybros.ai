module AgentLoops
  # A receipt for which neither model resolved retains its prompt on the
  # variant and has no prepared node input. Its first successful selection
  # compiles that input once; every later round/retry keeps the sealed seed.
  module MailSeed
    module_function

    def pending?(node)
      node.node_key == Conversations::Inputs::ApplyNext::SEED_ROUND_KEY &&
        node.agent_loop.kernel_mail? && node.input_body.nil?
    end

    # The caller holds the loop lock. The conversation and its earlier
    # turns are read only; the new bodies belong to the existing seed node
    # and to this loop's own variant (an insert under the foreign key's
    # key-share, never a row lock), so no conversation/variant lock is
    # acquired in the reverse order.
    # As with explicit regeneration, a template has no separate snapshot:
    # recovery reads the current template under the loop's frozen mechanism.
    def prepare(node:, selection:)
      agent_loop = node.agent_loop
      turn = agent_loop.conversation_turn
      conversation = turn.conversation
      prompt = agent_loop.conversation_turn_variant.content_bodies.find_by(role: "prompt")
      if agent_loop.raw?
        ContentBodies::CloneSealed.call(source: prompt, owner: node, role: "input")
        return
      end

      template = PromptTemplate.for_shell(agent_loop.prompt_mechanism, turn.declaring_profile)
      return :prompt_template_missing unless template

      refusal = template.turn_refusal(variables: nil, inline: nil)
      return refusal if refusal
      budget = Conversations::ContextAssembly::HistoryBudget.call(
        share: template.history_share, limits: selection.capabilities.limits
      )
      return budget.outcome unless budget.accepted?

      assembled = Conversations::ContextAssembly.assemble(
        memory_context: agent_loop.memory_context,
        conversation: conversation, principal: agent_loop.creating_user,
        prompt: Conversations::ContextAssembly::SpeakerEnvelope.for_turn(turn, prompt&.readable_text),
        attachments: prompt&.upload_parts || [], before_position: turn.position,
        profile: selection.execution_profile, limits: selection.capabilities.limits,
        history_token_budget: budget.value, template: template,
        reasoning: Conversations::ContextAssembly::Replay.from_selection(selection,
          mode: ("none" if conversation.reasoning_replay_downgraded_at)),
        declaring_profile: turn.declaring_profile, answerer: turn.answering_user,
        carries: Conversations::ContextAssembly::AttachmentLine.carries_for(selection),
        tools: node.tool_definitions
      )
      # An implicit fit wall is not permission to discard older context —
      # nor the traces that ride with it, which the fit prices beside it, so
      # a reasoning-heavy conversation reaches the wall sooner. This turn
      # already owns the loop, so preparing it cannot acquire the
      # conversation lock to insert a between-turn summary. Keep the seed
      # absent instead of sending the silently trimmed request: the step
      # fails `history_exceeds_fit` and the loop waits at needs_attention for
      # a person's retry on a larger model. The candidate window's end is no
      # such wall here — a retry cannot change a turn count, and receipts are
      # small turns that pass it long before the window — so it sends the
      # newest window, narrated as the trim, and the next drain meets the
      # same end and arms the summary.
      if budget.value.nil? && assembled.history.skipped_reason == "budget_exceeded"
        return Conversations::Inputs::ApplyNext::FIT_WALL
      end

      normalized = ModelSelection::Workloads.normalize_workload_input(
        selection: selection, input: assembled.messages, uploads: assembled.uploads
      )
      return normalized.refusal unless normalized.accepted?

      result = ContentBodies::Replace.call(
        owner: node, role: "input", entries: Nexus::InputEntries.for(normalized.value.value),
        uploads: normalized.value.uploads, seal: true, composed: true
      )
      return result.refusal unless result.accepted?

      # The receipt's own preface, sealed beside the seed it compiled: its
      # variant carried none while it waited (ApplyNext assembled nothing).
      Conversations::ContextAssembly::Preface.seal(agent_loop.conversation_turn_variant, assembled.preface)
      if assembled.history.skipped_count.positive?
        AgentLoop::Narration.record(agent_loop, [{
          type: "context_trimmed",
          payload: {
            "history_selected" => assembled.history.selected_count,
            "history_skipped" => assembled.history.skipped_count,
            "history_skipped_reason" => assembled.history.skipped_reason,
          },
        }])
      end
      nil
    end
  end
end
