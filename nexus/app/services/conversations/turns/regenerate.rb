module Conversations
  module Turns
    # A new sample beside the original: copy a compatible sealed request,
    # otherwise rebuild from the saved prompt using its original input mode.
    # The old variant keeps rendering until the new one completes.
    #
    # A loop-backed origin gets its own new loop and retains the original
    # approval freeze. The kernel does not restore external effects; the
    # variant's `runner_effects` describes them for the caller to judge.
    class Regenerate
      Command = Data.define(:conversation, :turn_public_id, :acting_user,
        :provider_id, :model_ref, :reasoning_effort, :reasoning_enabled, :request_options,
        :agent_configuration, :model_selection, :fallback_models) do
        def initialize(reasoning_enabled: nil, agent_configuration: nil, model_selection: nil, fallback_models: nil, **) = super
      end

      class << self
        def call(command)
          new(command).call
        end

        # THE KERNEL'S OWN REGENERATION of a direct reply a provider's
        # classifier declined, on the next permitted captured fallback. The
        # converger decides it once, under the conversation lock it already
        # holds, before anything reads the reply as settled — so the door's
        # guards omit the manual door's standing check (the kernel acts),
        # terminal check (the turn never went idle), and archive gate
        # (accepted work finishes).
        # The sample asks as the refused one's
        # POSTER (`principal`), whose principal decides the memory rung and
        # the persona the prompt assembles; the answering agent would
        # assemble a different prompt than the one declined. The model
        # resolves with no effort of its own: a profile's ref names a model,
        # not the old model's reasoning vocabulary.
        def for_fallback(conversation:, turn:, principal:, configuration:)
          command = Command.new(conversation: conversation, turn_public_id: turn.public_id,
            acting_user: principal, provider_id: nil, model_ref: nil,
            reasoning_effort: nil, request_options: configuration)
          new(command, source: "fallback")
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
        2.times do
          @memory_preparation = nil
          @conversation.with_lock(requires_new: true) do
            result = locked_regenerate
            raise ActiveRecord::Rollback unless result.accepted?
          end
          break unless @memory_preparation

          @memory_preparation.prepare_defaults
        end
        return result unless result.accepted?

        # After the lock, as the drain does: a direct sample is admitted by
        # the invocation pump; a loop-backed sample's round one is minted by
        # a scheduler pass (`perform_later` defers itself past the commit).
        if @born_loop_id
          Runs::ScheduleJob.perform_later(@born_loop_id)
        else
          ModelInvocations::AdmitQueuedWorkJob.perform_later
        end
        result
      end

      # A savepoint, never a second lock: the caller holds the row, and a
      # refused write unwinds the sample it began. The invocation pump
      # admits it once the caller commits.
      def fallback(turn, origin, selection)
        @conversation = @command.conversation
        result = nil
        @conversation.transaction(requires_new: true) do
          result = locked_fallback(turn, origin, selection)
          raise ActiveRecord::Rollback unless result.accepted?
        end
        ModelInvocations::AdmitQueuedWorkJob.perform_later if result.accepted?
        result
      end

      # The recovery chooser checks the same assembled request before selecting
      # and narrating a candidate. Keep the accepted assembly on this operation
      # so creation seals those same bytes without resolving or assembling again.
      # This path seals no body and creates no work.
      def fallback_refusal(turn, origin, selection)
        @conversation = @command.conversation
        @turn = turn
        @turn_position = turn.position
        prepare_declaration(origin) || candidate_refusal(selection)
      end

      private

        def locked_regenerate
          turn = @conversation.turns
            .find_by(public_id: @command.turn_public_id)
          refusal = turn_refusal(turn)
          return Outcome.refused(refusal) if refusal
          return Outcome.refused(:conversation_busy) unless turn.terminal?

          origin = turn.active_variant
          return Outcome.refused(:variant_not_active) if origin.nil? || origin.deleted?
          if origin.details_pruned_at || origin.run&.details_pruned_at
            return Outcome.refused(:execution_details_pruned)
          end
          # A hold-settled loop shapes its turn `failed` while the loop is
          # still ADJUDICABLE: the sibling is born `active: false`, so
          # `overridden?` stays false for the origin and `retry` or the
          # repairing append would run beside the sibling's loop — two live
          # loops behind one turn. Adjudicate first.
          if origin.run&.needs_attention?
            return Outcome.refused(:run_needs_attention)
          end

          @turn = turn
          @turn_position = turn.position
          @origin_loop = origin.run if origin.source == "run"
          @origin_seed = @origin_loop&.tasks&.find_by!(node_key: Inputs::ApplyNext::SEED_ROUND_KEY)

          refusal = prepare_declaration(origin)
          return Outcome.refused(refusal) if refusal

          selection, refusal = resolve_selection(origin)
          return Outcome.refused(refusal) if refusal

          Runs::Stop.mark_now(@origin_loop) if @origin_loop
          create_regeneration(turn, origin, selection)
        end

        # The declined sample is the origin, whatever the turn renders.
        def locked_fallback(turn, origin, selection)
          refusal = turn_refusal(turn, allow_archived: true)
          return Outcome.refused(refusal) if refusal

          @model_selection = origin.model_selection || ModelSelectionIntent.default("#{origin.provider_id}/#{origin.model_ref}")
          @fallback_models = origin.fallback_models || []
          @configuration = @command.request_options
          create_regeneration(turn, origin, selection)
        end

        # Accepted recovery may finish after archive; only the manual door
        # requires an unarchived conversation.
        def turn_refusal(turn, allow_archived: false)
          if @conversation.tombstoned? then :not_found
          elsif !allow_archived && @conversation.archived? then :conversation_archived
          elsif turn.nil? || turn.deleted? then :not_found
          elsif turn.kind != "direct_reply" then :unsupported_turn_type
          elsif !turn.tail? then :branch_required
          end
        end

        def prepare_declaration(origin)
          @agent_configuration = AgentConfiguration.to_type.cast(@command.agent_configuration) || origin.agent_configuration
          @executor_contexts = origin.agent_configuration&.executor_contexts || @origin_seed&.operation_context&.fetch("executor_contexts", nil)
          @agent_configuration.executor_contexts = @executor_contexts if @agent_configuration
          return :agent_configuration_invalid if @agent_configuration && !@agent_configuration.valid?

          @memory_context = if @command.agent_configuration
            MemoryContext.capture(configuration: @conversation.effective_memory_context(execution_configuration: @agent_configuration),
              speaker: @turn.speaker)
          else
            origin.memory_context || { "bindings" => [] }
          end
          if @command.agent_configuration
            context = MemoryDocuments::Context.new(workspace: @conversation.workspace, conversation: @conversation,
              principal: @command.acting_user, configuration: @memory_context, agent: @turn.execution_agent, execution: true)
            if context.defaults_missing?
              @memory_preparation = context
              return :stale_context_revision
            end
            refusal = context.selection_refusal
            return refusal if refusal

            @memory_context = context.capture
          end
          @compile_declaration = @command.agent_configuration || (@origin_loop.nil? && @agent_configuration)
          if @compile_declaration
            @tool_assembly = Tools::Assemble.for_agent(agent: @turn.execution_agent,
              declaration: @agent_configuration, runner: @conversation.default_runner)
            return @tool_assembly.refusal if @tool_assembly.refused?
          end
          nil
        end

        def loop_execution? = @compile_declaration ? @agent_configuration.tool_approval_required? : @origin_loop

        def execution_tools = @tool_assembly ? @tool_assembly.definitions.presence : @origin_seed&.tool_definitions

        # Default = the origin's frozen selection, re-resolved against the
        # CURRENT catalog; caller overrides re-ask on a different model.
        # Runs on both branches: it validates a caller's override and
        # yields the `selection` that `clone_safe?` and the assembly's
        # limits need. On ANOTHER model the origin's effort stays behind
        # unless the caller names one: it is the old model's vocabulary, so
        # the new model resolves at its own default, as the fallback does.
        def resolve_selection(origin)
          current = Runs::CurrentModel.for_variant(origin)
          provider_id = @command.provider_id.presence || current.provider_id
          model_ref = @command.model_ref.presence || current.model_ref
          return [nil, :model_selection_missing] if provider_id.blank? || model_ref.blank?

          moved = [provider_id, model_ref] != [current.provider_id, current.model_ref]
          effort = @command.reasoning_effort.presence || (current.reasoning_effort unless moved)
          enabled = @command.reasoning_enabled
          enabled = current.reasoning_enabled if enabled.nil? && !moved
          @configuration = request_configuration(origin, moved)
          @model_selection = ModelSelectionIntent.to_type.cast(@command.model_selection) ||
            (origin.model_selection unless moved) || ModelSelectionIntent.default("#{provider_id}/#{model_ref}")
          @fallback_models = @command.fallback_models ||
            (@agent_configuration.fallback_models if @command.agent_configuration) || origin.fallback_models || []
          return [nil, :model_selection_invalid] unless @model_selection.valid?
          return [nil, :fallback_models_invalid] unless ModelReferencesValidator.valid_value?(@fallback_models)

          resolve("#{provider_id}/#{model_ref}", effort, @configuration, enabled: enabled)
        end

        # One selection against the CURRENT catalog under a configuration.
        # Answers `[selection, nil]` or `[nil, refusal]`.
        def resolve(model, effort, configuration, enabled: nil)
          resolved = ModelSelection::Recovery.resolve(
            account: @conversation.account,
            workload: "text_generation",
            submitted: Nexus::SubmittedModelSelection.new(model: model, reasoning_effort: effort,
              reasoning_enabled: enabled),
            configuration: InferenceRequests::CoerceConfiguration.call(configuration),
            model_selection: @model_selection, fallback_models: @fallback_models,
            port: ModelSelection::Resolver.new
          ) { |candidate| candidate_refusal(candidate) }
          @model_skips = resolved.skips
          @model_change = if resolved.resolved? && "#{resolved.selection.provider_id}/#{resolved.selection.model_ref}" != model
            Runs::ModelFallback.from_selection(resolved.selection, reason: @model_skips.first.fetch("reason"))
              .narration(model).fetch("model_change")
          end
          resolved.resolved? ? [resolved.selection, nil] : [nil, resolved.refusal]
        end

        def candidate_refusal(selection)
          refusal = ModelSelection::Recovery.tools_refusal(selection, execution_tools)
          return refusal if refusal

          normalized, refusal = assemble_request(selection, tools: execution_tools)
          refusal ||= ModelSelection::Recovery.context_refusal(selection, normalized.value)
          @prepared_request = normalized unless refusal
          refusal
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
            Runs::ModelFallback.chosen_configuration(invocation)
          else
            invocation.request_options.except("instructions", Nexus::PromptCache::RequestKind::FACT)
          end
        end

        # A loop-backed candidate repeats its frozen execution. An edited or
        # forked answer compiles its retained declaration; an explicit
        # replacement chooses the new execution's surface at this boundary.
        def create_regeneration(turn, origin, selection)
          variant = Variant.create!(
            account: @conversation.account,
            turn: turn,
            position: (turn.variants.maximum(:position) || -1) + 1,
            status: "running",
            source: loop_execution? ? "run" : @source,
            context_mode: origin.context_mode,
            memory_context: @memory_context,
            agent_configuration: @agent_configuration&.with_tools(execution_tools || []),
            model_selection: @model_selection, fallback_models: @fallback_models,
            origin_variant_id: origin.id,
            provider_id: selection.provider_id,
            model_ref: selection.model_ref,
            reasoning_effort: selection.reasoning.effort,
            reasoning_enabled: selection.reasoning.enabled,
          )
          refusal =
            if loop_execution?
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
          source = seed&.content_bodies&.find_by(role: "input")
          seeding =
            # A retry can rebuild a never-invoked mail seed for a replacement
            # model. Only the first generation is described by the variant's
            # initial choice; later generations reassemble for the new target.
            if source && seed.execution_generation.zero? && clone_safe?(origin, selection, source)
              { seed_source: source }
            else
              assembled, refusal = @prepared_request ? [@prepared_request, nil] : assemble_request(selection, tools: execution_tools)
              return refusal if refusal

              { seed_body: assembled.value, seed_uploads: assembled.uploads }
            end

          born = BackingRun.create(
            conversation: @conversation, variant: variant, creating_user: @command.acting_user,
            steps: [seed_step(seed, selection)],
            tip: Runs::Tasks::Tip.seed(Runs::Tasks::Compile::ROUND),
            prompt_mechanism: @compile_declaration ? (origin.context_mode == "raw" ? "raw" : @agent_configuration.prompt_mechanism || "default") : origin_loop&.prompt_mechanism,
            approval_mode: @compile_declaration ? @agent_configuration.approval_mode : origin_loop&.approval_mode,
            approval_rules: @compile_declaration ? @agent_configuration.approval_rules : origin_loop&.approval_rules,
            lifecycle_hooks: @compile_declaration ? @agent_configuration.lifecycle_hooks : origin_loop&.lifecycle_hooks,
            memory_context: @memory_context,
            conversation_reach: @compile_declaration ? @conversation.effective_conversation_reach(execution_configuration: @agent_configuration) : origin_loop&.conversation_reach,
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
          Runs::Tasks::Step::Model.new(
            key: Inputs::ApplyNext::SEED_ROUND_KEY,
            model: {
              "model" => "#{selection.provider_id}/#{selection.model_ref}",
              "reasoning_effort" => selection.reasoning.effort,
              "reasoning_enabled" => selection.reasoning.enabled,
            }.compact,
            configuration: @configuration,
            model_selection: @model_selection.as_json, fallback_models: @fallback_models,
            instructions: seed&.system_instructions,
            tools: execution_tools,
            executor_contexts: @executor_contexts,
            environment: @tool_assembly ? @tool_assembly.environment : seed&.operation_context&.fetch("environment", nil),
            compaction: @compile_declaration ? @agent_configuration.compaction_policy : seed&.compaction,
            visibility: seed&.transcript_visibility || "visible",
            lifetime: seed&.lifetime || "conversation"
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
            assembled, refusal = @prepared_request ? [@prepared_request, nil] : assemble_request(selection, tools: nil)
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
          return false if @command.agent_configuration
          return false unless origin.provider_id == selection.provider_id &&
            origin.model_ref == selection.model_ref &&
            selection.reasoning.enabled != false
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
          template = PromptTemplate.for_configuration(@agent_configuration || @turn.execution_agent)
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
            execution_agent: @turn.execution_agent,
            agent_configuration: @agent_configuration,
            answerer: @turn.answering_user,
            # Every picture in the window re-placed under the re-ask's
            # engine: native or the index line per part, per turn.
            carries: ContextAssembly::AttachmentLine.carries_for(selection),
            # The regenerated execution's tools, frozen on the original seed.
            # An edited or forked candidate has no tool execution to repeat.
            tools: tools,
            environment: @tool_assembly ? @tool_assembly.environment : @origin_seed&.operation_context&.fetch("environment", nil)
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
              "model_skips" => @model_skips&.presence, "model_change" => @model_change,
            }.compact,
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
          Event::Append.call(
            host: @conversation,
            idempotency_key: variant.public_id,
            items: items
          )
        end
    end
  end
end
