module Conversations
  module Turns
    # A new sample beside the original: copy a compatible sealed request,
    # otherwise rebuild from the saved prompt using its original input mode.
    # The old variant keeps rendering until the new one completes.
    #
    # A loop-backed origin gets its own new loop and retains the original
    # approval freeze. The kernel does not restore external effects; the
    # variant's `world` describes them for the caller to judge.
    class Regenerate
      Command = Data.define(:conversation, :turn_public_id, :acting_user,
        :provider_id, :model_ref, :reasoning_effort, :request_options)

      class << self
        def call(command)
          new(command).call
        end

        # THE KERNEL'S OWN REGENERATION of a direct reply a provider's
        # classifier declined, on the answering profile's declared fallback
        # (`candidate`, an `AgentLoops::ModelFallback::Candidate`). The
        # converger decides it once, under the conversation lock it already
        # holds, before anything reads the reply as settled — so the door's
        # guards run minus two: no standing check (the kernel acts, no
        # member does) and no terminal check (the turn is still running on
        # purpose: it never went idle). The sample asks as the refused one's
        # POSTER (`principal`), whose principal decides the memory rung and
        # the persona the prompt assembles; the answering agent would
        # assemble a different prompt than the one declined. The model
        # resolves with no effort of its own: a profile's ref names a model,
        # not the old model's reasoning vocabulary.
        def fallback(conversation:, turn:, origin:, candidate:, principal:)
          command = Command.new(conversation: conversation, turn_public_id: turn.public_id,
            acting_user: principal, provider_id: candidate.provider_id, model_ref: candidate.model_ref,
            reasoning_effort: nil, request_options: nil)
          new(command, source: "fallback").fallback(turn, origin)
        end
      end

      def initialize(command, source: "inference")
        @command = command
        @source = source
      end

      def call
        unless @command.conversation.writable_by?(@command.acting_user)
          return Outcome.refused(:not_authorized)
        end

        result = nil
        @conversation = @command.conversation
        @conversation.with_lock(requires_new: true) do
          result = locked_regenerate
          raise ActiveRecord::Rollback unless result.accepted?
        end
        return result unless result.accepted?

        # After the lock, as the drain does: a direct sample is admitted by
        # the invocation pump; a loop-backed sample's round one is minted by
        # a scheduler pass (`perform_later` defers itself past the commit).
        if @born_loop_id
          AgentLoops::ScheduleJob.perform_later(@born_loop_id)
        else
          ModelInvocations::AdmitQueuedWorkJob.perform_later
        end
        result
      end

      # A savepoint, never a second lock: the caller holds the row, and a
      # refused assembly unwinds the sample it began. The invocation pump
      # admits it once the caller commits.
      def fallback(turn, origin)
        @conversation = @command.conversation
        result = nil
        @conversation.transaction(requires_new: true) do
          result = locked_fallback(turn, origin)
          raise ActiveRecord::Rollback unless result.accepted?
        end
        ModelInvocations::AdmitQueuedWorkJob.perform_later if result.accepted?
        result
      end

      private

        def locked_regenerate
          turn = @conversation.conversation_turns
            .find_by(public_id: @command.turn_public_id)
          refusal = turn_refusal(turn)
          return Outcome.refused(refusal) if refusal
          return Outcome.refused(:conversation_busy) unless turn.terminal?

          origin = turn.active_variant
          return Outcome.refused(:variant_not_active) if origin.nil? || origin.deleted?
          if origin.details_pruned_at || origin.agent_loop&.details_pruned_at
            return Outcome.refused(:execution_details_pruned)
          end
          # A hold-settled loop shapes its turn `failed` while the loop is
          # still ADJUDICABLE: the sibling is born `active: false`, so
          # `overridden?` stays false for the origin and `retry` or the
          # repairing append would run beside the sibling's loop — two live
          # loops behind one turn. Adjudicate first.
          if origin.agent_loop&.needs_attention?
            return Outcome.refused(:loop_needs_attention)
          end

          @turn = turn
          @turn_position = turn.position
          @origin_loop = origin.agent_loop if origin.source == "agent_loop"
          @origin_seed = @origin_loop&.agent_loop_nodes&.find_by!(node_key: Inputs::ApplyNext::SEED_ROUND_KEY)

          selection, refusal = resolve_selection(origin)
          return Outcome.refused(refusal) if refusal

          AgentLoops::Stop.mark_now(@origin_loop) if @origin_loop
          create_regeneration(turn, origin, selection)
        end

        # The declined sample is the origin, whatever the turn renders.
        def locked_fallback(turn, origin)
          refusal = turn_refusal(turn)
          return Outcome.refused(refusal) if refusal

          @turn = turn
          @turn_position = turn.position
          # The caller's own parameters, never the declining model's
          # defaults (`ModelFallback.chosen_configuration`).
          @configuration = AgentLoops::ModelFallback.chosen_configuration(origin.model_invocation)
          selection, refusal = resolve("#{@command.provider_id}/#{@command.model_ref}", nil, @configuration)
          return Outcome.refused(refusal) if refusal

          create_regeneration(turn, origin, selection)
        end

        # What any regeneration needs of the turn it aims at: a live,
        # unarchived conversation, and its live tail direct reply.
        def turn_refusal(turn)
          if @conversation.tombstoned? then :not_found
          elsif @conversation.archived? then :conversation_archived
          elsif turn.nil? || turn.deleted? then :not_found
          elsif turn.kind != "direct_reply" then :unsupported_turn_type
          elsif !turn.tail? then :branch_required
          end
        end

        # Default = the origin's frozen trio, re-resolved against the
        # CURRENT catalog; caller overrides re-ask on a different model.
        # Runs on both branches: it validates a caller's override and
        # yields the `selection` that `clone_safe?` and the assembly's
        # limits need. On ANOTHER model the origin's effort stays behind
        # unless the caller names one: it is the old model's vocabulary, so
        # the new model resolves at its own default, as the fallback does.
        def resolve_selection(origin)
          current = AgentLoops::CurrentModel.for_variant(origin)
          provider_id = @command.provider_id.presence || current.provider_id
          model_ref = @command.model_ref.presence || current.model_ref
          return [nil, :model_selection_missing] if provider_id.blank? || model_ref.blank?

          moved = [provider_id, model_ref] != [current.provider_id, current.model_ref]
          effort = @command.reasoning_effort.presence || (current.reasoning_effort unless moved)
          @configuration = request_configuration(origin, moved)
          resolve("#{provider_id}/#{model_ref}", effort, @configuration)
        end

        # One trio against the CURRENT catalog under a configuration.
        # Answers `[selection, nil]` or `[nil, refusal]`.
        def resolve(model, effort, configuration)
          resolved = ModelSelection.resolve(
            account: @conversation.account,
            workload: "text_generation",
            submitted: Nexus::SubmittedModelSelection.new(model: model, reasoning_effort: effort),
            configuration: OneShots::CoerceConfiguration.call(configuration),
            port: ModelSelection::Resolver.new
          )
          resolved.resolved? ? [resolved.selection, nil] : [nil, resolved.refusal]
        end

        # Omission repeats the origin's configuration; an explicit object
        # replaces it, including an empty object selecting current defaults.
        # Raw instructions are request content, not generation parameters.
        # A sample sealed its model's RESOLVED options, that model's catalog
        # defaults included, so a re-ask on another model carries only what
        # the caller chose (`ModelFallback.chosen_configuration`, the one
        # reader the kernel's own fallback uses): the old defaults would
        # refuse every model whose parameter vocabulary differs. A seed's
        # options are the submitted ones already.
        def request_configuration(origin, moved)
          return @command.request_options unless @command.request_options.nil?

          invocation = origin.model_invocation
          if @origin_seed
            @origin_seed.request_options
          elsif invocation.nil?
            {}
          elsif moved
            AgentLoops::ModelFallback.chosen_configuration(invocation)
          else
            invocation.request_options.except("instructions", Nexus::PromptCache::RequestKind::FACT)
          end
        end

        # The branch is the origin's SOURCE: a loop-backed candidate births
        # a loop-backed sibling with its own loop, everything else an
        # inference sample behind a model invocation. A fork-ADOPTED turn
        # (`source: "fork"`, no loop) regenerates by inference, as today.
        def create_regeneration(turn, origin, selection)
          @memory_context = origin.memory_context
          variant = ConversationTurnVariant.create!(
            account: @conversation.account,
            conversation_turn: turn,
            position: (turn.conversation_turn_variants.maximum(:position) || -1) + 1,
            status: "running",
            source: @origin_loop ? "agent_loop" : @source,
            context_mode: origin.context_mode,
            memory_context: origin.memory_context,
            origin_variant_id: origin.id,
            provider_id: selection.provider_id,
            model_ref: selection.model_ref,
            reasoning_effort: selection.reasoning.effort,
          )
          refusal =
            if @origin_loop
              back_with_loop(origin, @origin_loop, variant, selection)
            else
              back_with_invocation(origin, variant, selection)
            end
          return Outcome.refused(refusal) if refusal

          carry_prompt(origin, variant)
          carry_preface(origin, variant)
          # The reopen: terminal -> running on the tail, the one deliberate
          # exception; the old candidate keeps rendering meanwhile.
          turn.update!(status: "running")
          @conversation.update!(
            active_turn: turn,
            last_activity_at: Time.current,
          )
          narrate(turn, variant)
          Outcome.accepted(variant)
        end

        def back_with_invocation(origin, variant, selection)
          options = selection.generation_config.to_h.merge(Nexus::PromptCache::RequestKind::FACT =>
            Nexus::PromptCache::RequestKind.stamp(Nexus::PromptCache::RequestKind.for_conversation(@conversation)))
          if origin.model_invocation
            options = options.merge(origin.model_invocation.request_options.slice("instructions"))
          end
          invocation = ModelInvocation.create_for_selection(
            selection: selection,
            conversation: @conversation,
            creating_user: @command.acting_user,
            internal_creation_key: "conversation_reply:#{variant.public_id}",
            request_options: options
          )
          refusal = build_request(origin, invocation, selection)
          return refusal if refusal

          variant.update!(model_invocation_id: invocation.id)
          nil
        end

        # The loop repeats the original seed's tools and instructions with
        # the resolved model and configuration. Its input uses the same
        # clone-or-rebuild choice as direct inference; approval and prompt
        # mechanism stay frozen to the origin loop, not today's profile.
        def back_with_loop(origin, origin_loop, variant, selection)
          seed = @origin_seed
          source = seed.content_bodies.find_by(role: "input")
          seeding =
            # A retry can rebuild a never-invoked mail seed for a replacement
            # model. Only the first generation is described by the variant's
            # initial choice; later generations reassemble for the new target.
            if source && seed.execution_generation.zero? && clone_safe?(origin, selection, source)
              { seed_source: source }
            else
              assembled, refusal = assemble_request(selection, tools: seed.tool_definitions)
              return refusal if refusal

              { seed_body: assembled.value, seed_uploads: assembled.uploads }
            end

          born = BackingLoop.create(
            conversation: @conversation, variant: variant, creating_user: @command.acting_user,
            steps: [seed_step(seed, selection)],
            tip: AgentLoops::Tasks::Tip.seed(AgentLoops::Tasks::Compile::ROUND),
            prompt_mechanism: origin_loop.prompt_mechanism,
            approval_mode: origin_loop.approval_mode,
            approval_rules: origin_loop.approval_rules,
            lifecycle_hooks: origin_loop.lifecycle_hooks,
            memory_context: origin_loop.memory_context,
            **seeding
          )
          return born.outcome unless born.accepted?

          @born_loop_id = born.value.id
          nil
        end

        # The seed's shape as the drain authors it (`ApplyNext#seed_round`):
        # the origin seed node's frozen tools, options, system field,
        # compaction policy and visibility, and the TRIO spelled as the
        # scheduler's string — `selection`'s, the origin's unless the caller
        # re-asked. A caller's `configuration` re-asks under its own
        # submitted options, as it does on the invocation branch.
        def seed_step(seed, selection)
          AgentLoops::Tasks::Step::Model.new(
            key: Inputs::ApplyNext::SEED_ROUND_KEY,
            model: {
              "model" => "#{selection.provider_id}/#{selection.model_ref}",
              "reasoning_effort" => selection.reasoning.effort,
            }.compact,
            configuration: @configuration,
            instructions: seed.system_instructions,
            tools: seed.tool_definitions,
            compaction: seed.compaction,
            visibility: seed.transcript_visibility,
            lifetime: seed.lifetime
          )
        end

        # The seed is the TURN's question, the same for every candidate
        # answer: the sibling carries the origin's `prompt` body, so the
        # next turn's history still opens the turn with its words.
        def carry_prompt(origin, variant)
          prompt = origin.content_bodies.find_by(role: "prompt")
          ContentBodies::CloneSealed.call(source: prompt, owner: variant, role: "prompt") if prompt
        end

        # And so is the per-turn text it asked with: the clone branch's copied
        # request carries the origin's preface, so the sibling clones it; the
        # rebuilt one lays it verbatim (`assemble_request`) — save a lead the
        # origin relied on the window for, laid when this window no longer
        # carries it — so the sibling seals what its own request laid.
        def carry_preface(origin, variant)
          if @assembled_preface
            ContextAssembly::Preface.seal(variant, @assembled_preface)
          else
            preface = origin.content_bodies.find_by(role: ContextAssembly::Preface::ROLE)
            ContentBodies::CloneSealed.call(source: preface, owner: variant, role: ContextAssembly::Preface::ROLE) if preface
          end
        end

        def build_request(origin, invocation, selection)
          source = origin.model_invocation&.content_bodies&.find_by(role: "request")
          if source && clone_safe?(origin, selection, source)
            ContentBodies::CloneSealed.call(
              source: source, owner: invocation, role: "request"
            )
            nil
          else
            assembled, refusal = assemble_request(selection, tools: nil)
            return refusal if refusal

            written = ContentBodies::Replace.call(
              owner: invocation, role: "request",
              entries: Nexus::InputEntries.for(assembled.value),
              uploads: assembled.uploads,
              seal: true
            )
            written.accepted? ? nil : written.refusal
          end
        end

        # A different target rechecks the saved prompt's input policy. A
        # replay downgrade also rebuilds native-bearing requests: assembly
        # omits default replay, while raw retains its explicit content and
        # leaves native-origin compatibility to the wire builder.
        # `source` is the sealed body in question: an invocation's
        # `request`, or a loop's seed `input`.
        def clone_safe?(origin, selection, source)
          return false unless origin.provider_id == selection.provider_id &&
            origin.model_ref == selection.model_ref &&
            selection.reasoning.effort.to_s != "none"
          return true unless @conversation.reasoning_replay_downgraded_at

          !source.native_reasoning?
        end

        # The assembly alone — the normalized value and the uploads it
        # places — with the write left to the branch: the invocation branch
        # seals it as the invocation's `request`, the loop branch hands it
        # to the seam's writer as the seed's input. Answers `[value, nil]`
        # or `[nil, refusal]`.
        def assemble_request(selection, tools:)
          prompt = @turn.active_variant.content_bodies.find_by(role: "prompt")
          if @turn.active_variant.context_mode == "raw"
            return restore_raw_request(prompt, selection)
          end

          # Assembled history excludes the old answer; the turn's question
          # remains the input, including its speaker and attachments.
          # The kill-switch silences the target row's default replay.
          replay_mode = ("none" if @conversation.reasoning_replay_downgraded_at)
          # The turn's answerer's template: its history block's share, if
          # any, maps as the drain's would; `history` is exactly once in
          # every template, so the question always rides.
          template = PromptTemplate.for_profile(@turn.declaring_profile)
          budget = ContextAssembly::HistoryBudget.call(
            share: template.history_share, limits: selection.capabilities.limits
          )
          return [nil, budget.outcome] unless budget.accepted?

          assembled = ContextAssembly.assemble(
            conversation: @conversation, principal: @command.acting_user,
            memory_context: @memory_context,
            prompt: ContextAssembly::SpeakerEnvelope.for_turn(@turn, prompt&.readable_text),
            attachments: prompt&.upload_parts || [],
            # The turn's question includes the per-turn text it carried:
            # its sealed preface, never today's template re-rendered.
            preface: ContextAssembly::Preface.laid(
              @turn.active_variant.content_bodies.find_by(role: ContextAssembly::Preface::ROLE)
            ),
            before_position: @turn_position,
            profile: selection.execution_profile,
            limits: selection.capabilities.limits,
            history_token_budget: budget.value,
            template: template,
            reasoning: ContextAssembly::Replay.from_selection(selection, mode: replay_mode),
            # The TURN's answerer declares: a regenerated variant derives from
            # the same turn — B's turn re-asks under B's engine and
            # `system_prompt`, whatever the conversation's default.
            declaring_profile: @turn.declaring_profile,
            answerer: @turn.answering_user,
            # Every picture in the window re-placed under the re-ask's
            # engine: native or the index line per part, per turn.
            carries: ContextAssembly::AttachmentLine.carries_for(selection),
            # The regenerated execution's tools, frozen on the original seed.
            # An edited or forked candidate has no tool execution to repeat.
            tools: tools
          )
          @assembly_history = assembled.history
          @assembled_preface = assembled.preface
          normalized = ModelSelection::Workloads.normalize_workload_input(
            selection: selection, input: assembled.messages, uploads: assembled.uploads
          )
          normalized.accepted? ? [normalized.value, nil] : [nil, normalized.refusal]
        end

        # Raw owns the whole message list. A new model rechecks its media
        # and size policy, but never adds history or flattens message roles.
        # Native-origin compatibility remains the wire builder's decision.
        def restore_raw_request(prompt, selection)
          return [nil, ModelRequests::Build::MISSING_INPUT] if prompt.nil?

          value = Nexus::InputEntries.from(entries: prompt.entry_payloads, workload: "text_generation")
          accepted = ModelSelection::Workloads.accept_normalized_input(
            selection: selection, input: value, uploads: prompt.content_uploads.to_a
          )
          accepted.accepted? ? [accepted.value, nil] : [nil, accepted.refusal]
        end

        def narrate(turn, variant)
          items = [{
            type: "turn_variant",
            payload: {
              "turn_public_id" => turn.public_id,
              "variant_public_id" => variant.public_id,
              "regenerating" => true,
            },
          }]
          # The kernel's fallback reopens nothing: the converger narrates
          # the turn once, still running, beside the refusal it answers.
          unless variant.fallback?
            items << {
              type: "turn_status",
              payload: {
                "turn_public_id" => turn.public_id,
                "turn_kind" => turn.kind,
                "variant_public_id" => variant.public_id,
                "status" => "running",
              },
            }
          end
          # Narrated whenever history was left out; the clone path has
          # nothing new to say.
          history = @assembly_history
          if history && history.skipped_count.positive?
            items << {
              type: "context_trimmed",
              payload: {
                "turn_public_id" => turn.public_id,
                "history_selected" => history.selected_count,
                "history_skipped" => history.skipped_count,
                "history_skipped_reason" => history.skipped_reason,
              },
            }
          end
          ConversationEvent::Append.call(
            host: @conversation,
            idempotency_key: variant.public_id,
            items: items
          )
        end
    end
  end
end
