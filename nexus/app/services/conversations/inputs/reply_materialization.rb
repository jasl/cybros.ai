module Conversations
  module Inputs
    # The shared turn, seed and loop writers behind the conversation input door.
    module ReplyMaterialization
      private

        # A missing model cannot erase a receipt or block the immutable
        # queue head. Keep the prompt under the same loop that will
        # own the refusal, its single fallback, and any explicit retry.
        # No provider request is invented: the normal scheduler resolves
        # the model and applies its window/compaction gates before sending.
        def materialize_unavailable_result_delivery(input)
          result = nil
          ApplicationRecord.transaction(requires_new: true) do
            result = materialize_loop(input, nil, nil, [], nil)
            raise ActiveRecord::Rollback unless result.accepted?
          end
          result.accepted? ? result : park(input, result.outcome)
        end

        # The running assistant turn and its variant, the one shape both
        # engines write; only `source` tells them apart. The turn records
        # who ANSWERED: the input's addressee, whose engine this is — the
        # poster keeps the voice and the control.
        def build_reply_turn(input, selection, source:)
          unresolved = @result_delivery_fallback || input
          turn = ConversationTurn.create!(
            account: @conversation.account,
            conversation: @conversation,
            position: @conversation.timeline_position_head,
            kind: "direct_reply",
            role: "assistant",
            status: "running",
            speaker: input.speaker,
            control_owner_user: input.authoring_user,
            answering_user: input.answering_user,
            visibility: input.visible_in_context ? "visible" : "excluded_from_context",
            origin: input.origin,
            input_public_id: input.public_id,
            callback_sources: @independent_callback_sources || [input.callback_source].compact,
            sender_conversation_public_id: @independent_callback_sources ? nil : input.sender_conversation_public_id,
            sender_run_public_id: @independent_callback_sources ? nil : input.sender_run_public_id,
            sender_task_key: @independent_callback_sources ? nil : input.sender_task_key,
          )
          variant = ConversationTurnVariant.create!(
            account: @conversation.account,
            conversation_turn: turn,
            position: 0,
            status: "running",
            source: source,
            context_mode: input.raw? ? "raw" : "assembled",
            memory_context: input.execution_memory_context,
            provider_id: selection ? selection.provider_id : unresolved.provider_id,
            model_ref: selection ? selection.model_ref : unresolved.model_ref,
            reasoning_effort: selection ? selection.reasoning.effort : unresolved.reasoning_effort,
            reasoning_enabled: selection ? selection.reasoning.enabled : unresolved.reasoning_enabled,
          )
          [turn, variant]
        end

        def create_reply(input, selection, normalized, assembled)
          turn, variant = build_reply_turn(input, selection, source: "inference")
          invocation = ModelInvocation.create_for_selection(
            selection: selection,
            conversation: @conversation,
            creating_user: input.authoring_user,
            internal_creation_key: "conversation_reply:#{input.public_id}",
            request_options: reply_request_options(input, selection)
          )
          # The seal binds what it sends: the placed rows, so `Build`
          # finds them at `source.content_uploads`.
          request = ContentBodies::Replace.call(
            owner: invocation, role: "request",
            entries: Nexus::InputEntries.for(normalized.value.value),
            uploads: normalized.value.uploads,
            seal: true
          )
          return Outcome.refused(request.refusal) unless request.accepted?

          variant.update!(model_invocation_id: invocation.id)
          land_reply(input, turn, variant, assembled)
          ModelInvocations::AdmitQueuedWorkJob.perform_later
          Outcome.accepted(turn)
        end

        # The generation bag, plus `raw`'s own system field when the input
        # carries one: a request fact Build lifts off the bag, never a
        # generation control.
        # The reply's cache kind rides beside its generation controls: a
        # conversation's reply is its mainline (a subagent's, its parent's to
        # read back).
        def reply_request_options(input, selection)
          options = selection.generation_config.to_h.merge(Nexus::PromptCache::RequestKind::FACT =>
            Nexus::PromptCache::RequestKind.stamp(Nexus::PromptCache::RequestKind.for_conversation(@conversation)))
          return options if input.instructions.blank?

          options.merge("instructions" => input.instructions)
        end

        # A loop-backed turn through the seam's one writer
        # (`Turns::BackingRun`): round one's input body is the SAME
        # normalized request a direct reply seals, and the loop is born
        # running — the person's input is the start.
        def materialize_loop(input, selection, seed_body, seed_uploads, assembled)
          profile = input.declaring_profile
          approval_mode = input.approval_mode || profile&.approval_mode
          # A queued receipt can outlive the profile that supplied its
          # surface. Missing approval configuration uses the existing
          # message-only degradation; the kernel invents no default mode.
          return Outcome.refused(:approval_mode_required) if approval_mode.nil?

          turn, variant = build_reply_turn(input, selection, source: "run")
          born = Turns::BackingRun.create(
            conversation: @conversation, variant: variant, creating_user: input.authoring_user,
            steps: [seed_round(input, selection, profile)],
            authored_steps: input.steps, append_key: input.public_id,
            tip: AgentRuns::Tasks::Tip.seed(AgentRuns::Tasks::Compile::ROUND).with(
              lifetime: @delegation_lifetime || "conversation"),
            seed_body: seed_body,
            memory_context: input.execution_memory_context,
            seed_uploads: seed_uploads,
            # The effective word, written: `raw` when the input went
            # verbatim, `assembly` under the addressee's own template, else
            # the built-in `default` order.
            prompt_mechanism: input.effective_prompt_mechanism,
            # The approval freeze: the input's tightening, else the
            # profile's word — present on this lane by the profile's own
            # presence rule (tools declared ⇒ a mode declared).
            approval_mode: approval_mode,
            approval_rules: profile&.approval_rules
          )
          return born unless born.accepted?

          agent_run = born.value
          if @result_delivery_fallback
            agent_run.update!(result_delivery_model_fallback_used: true)
            previous = "#{input.provider_id}/#{input.model_ref}"
            # The switch as a row fact too, as every automatic switch writes
            # it: the seed says what it replaced.
            AgentRuns::Transition.node(agent_run.agent_run_tasks.find_by!(node_key: ApplyNext::SEED_ROUND_KEY),
              status: "queued", output_summary: @result_delivery_fallback.row_fact(previous),
              narration: @result_delivery_fallback.narration(previous))
          end
          land_reply(input, turn, variant, assembled, agent_run: agent_run)
          @materialized_loop_id = agent_run.id
          Outcome.accepted(turn)
        end

        # The configuration freeze onto round one: the declaration's tools —
        # narrowed by name to the input's `tool_names` when it names a subset,
        # through the one narrow a branch uses — and policy, the input's model
        # and SUBMITTED options (the scheduler re-resolves them as this lane
        # did). No instructions on the ASSEMBLED lane — the system channel
        # rides the sealed list, the slot blocks included. Under `raw` the
        # input's own `instructions` is the system field, ONE copy per round
        # in the wire's own slot, inherited by every continuation
        # (`Step.inheriting`). No prompt: the input body is the request. The
        # rest are the compiler's model-task defaults; the mark and the answer
        # are the tip's.
        def seed_round(input, selection, profile)
          unresolved = @result_delivery_fallback || input
          AgentRuns::Tasks::Step::Model.new(
            key: ApplyNext::SEED_ROUND_KEY,
            model: {
              "model" => selection ? "#{selection.provider_id}/#{selection.model_ref}" : "#{unresolved.provider_id}/#{unresolved.model_ref}",
              "reasoning_effort" => selection ? selection.reasoning.effort : unresolved.reasoning_effort,
              "reasoning_enabled" => selection ? selection.reasoning.enabled : unresolved.reasoning_enabled,
            }.compact,
            configuration: input.request_options,
            instructions: (input.instructions if input.raw?),
            # The input's `[]` (no tools) is the round's nil — the loop
            # plane's own spelling of a tool-less model task; the authoring
            # door reads an empty list as a typo, and this seed is the one
            # place that knows the list was the person's word.
            tools: @tool_assembly.definitions.presence,
            environment: @tool_assembly.environment,
            compaction: profile&.compaction_policy,
            visibility: "visible"
          )
        end

        # What both engines do once the turn stands: the pointer, the seed
        # and the preface, the input's death, the head bump and the turn's
        # own narration, in this order. `assembled` is nil when nothing was
        # assembled: a raw input, or kernel mail waiting on a model (its
        # preface is sealed when ResultDeliverySeed compiles it).
        def land_reply(input, turn, variant, assembled, agent_run: nil)
          turn.update!(active_variant: variant)
          keep_prompt(input, variant)
          ContextAssembly::Preface.seal(variant, assembled.preface) if assembled

          queue_position = input.queue_position
          @conversation.record_scheduled_turn(input, turn)
          input.destroy!

          @conversation.update!(
            timeline_position_head: turn.position + 1,
            active_turn: turn,
            last_activity_at: Time.current,
          )
          narrate_reply(turn, variant, queue_position, assembled&.history, agent_run)
        end

        # THE SEED: the input's body lives on as the variant's `prompt` —
        # the one durable, un-merged copy of the words that opened the
        # turn, which later history renders ahead of what the turn
        # produced. Seal-then-clone, zero bytes, as `adopt_content`; a raw
        # input's body is cloned too (the record of what opened the turn)
        # and renders only when it carries readable text.
        def keep_prompt(input, variant)
          body = input.content_body
          return if body.nil?

          body.seal
          ContentBodies::CloneSealed.call(source: body, owner: variant, role: "prompt")
        end
    end
  end
end
