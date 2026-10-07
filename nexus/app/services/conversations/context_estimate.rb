module Conversations
  # Advisory sizing of the assembled context: assembly is server-side, so a
  # client cannot count what it cannot see. Advisory only:
  # bytes enforce, the provider stays authoritative.
  #
  # THE PREVIEW is this same call (one door): the estimate
  # compiles exactly the send it models — under the ADDRESSEE the input
  # door would resolve, with the caller as the author — and, rendered,
  # answers the entries the seal would write, the storage bytes the seal
  # would judge, and each block's evidence. Nothing is written.
  class ContextEstimate
    # `acting_user` is the caller: the estimate models the send the caller
    # would make, and the caller IS the poster whose `user/` the block
    # renders. `answering_user_public_id` is the addressee (`to:`), nil for
    # the conversation's stored answerer; `variables` the turn's values for
    # the template's declared names; `template` an estimate-only TRIAL
    # template (never on an input) compiled in place of the addressee's;
    # `render` asks for the compiled bytes beside the count.
    Command = Data.define(
      :conversation, :acting_user, :provider_id, :model_ref, :reasoning_effort, :reasoning_enabled,
      :request_options, :prompt, :history_max_entries, :history_token_budget_share,
      :reasoning_replay_mode, :inline, :render, :answering_user_public_id, :variables, :template
    ) do
      def initialize(reasoning_enabled: nil, render: false, answering_user_public_id: nil, variables: nil, template: nil, **) = super
    end

    # What the send would seal: `mechanism` the word the compile ran under
    # (`assembly` under a trial template), `entries` the payloads the seal
    # writes, `storage` the one measure against the seal's bound (over it
    # the preview still answers, with the seal's refusal word), `blocks` the
    # template's evidence in its order (ContextAssembly::BlockEvidence),
    # `memory` and `slots` the two blocks' own evidence.
    Rendered = Data.define(:mechanism, :entries, :storage, :blocks, :memory, :slots)

    Estimate = Data.define(
      :input_tokens, :tokenizer_exact, :catalog_input_token_limit,
      :advisory_input_token_limit, :message_count, :selection,
      :history_selected, :history_skipped, :history_skipped_reason,
      :history_compacted, :rendered
    )

    class << self
      def call(command)
        new(command).call
      end
    end

    def initialize(command)
      @command = command
    end

    def call
      # The rule the drain applies (TurnPrincipals): the addressee the
      # door would resolve declares; the caller authors.
      resolved = TurnPrincipals.resolve(
        host: @command.conversation, author: @command.acting_user, address: @command.answering_user_public_id
      )
      return resolved unless resolved.accepted?

      principals = resolved.value
      tools = Tools::Assemble.for_profile(profile: principals.declaring_profile, runner: @command.conversation.default_runner)
      return Outcome.refused(tools.refusal) if tools.refused?

      # A raw addressee sends the input's own entries: there is nothing
      # here to compile, and a count of something else would be a lie.
      return Outcome.refused(:estimate_unavailable_under_raw) if principals.raw?

      template, mechanism, refusal = effective_template(principals)
      return refusal if refusal

      turn_refusal = template.turn_refusal(variables: @command.variables, inline: @command.inline)
      return Outcome.refused(turn_refusal) if turn_refusal

      # An addressed peer answers on its own engine, just as the input
      # door resolves it. The model determines both the history budget
      # and whether its attachments are carried or rendered as pointers.
      engine = AnswerEngine.selection(@command.conversation, addressee: principals.answerer) if
        principals.answerer.id != @command.conversation.answering_user_id
      # The submitted trio is the LAST rung of that ladder, so it is
      # required only when the ladder produced nothing — a preview that
      # refused a model the addressee itself supplies would refuse a send
      # the door accepts, at the one door whose whole contract is that the
      # two cannot drift.
      if engine.nil? && (@command.provider_id.blank? || @command.model_ref.blank?)
        return Outcome.refused(:model_selection_missing)
      end

      resolved = ModelSelection.resolve(
        account: @command.conversation.account,
        workload: "text_generation",
        submitted: Nexus::SubmittedModelSelection.new(
          model: engine ? "#{engine.provider_id}/#{engine.model_ref}" : "#{@command.provider_id}/#{@command.model_ref}",
          reasoning_effort: engine ? engine.reasoning_effort : @command.reasoning_effort,
          reasoning_enabled: engine ? engine.reasoning_enabled : @command.reasoning_enabled
        ),
        configuration: InferenceRequests::CoerceConfiguration.call(@command.request_options || {}),
        port: ModelSelection::Resolver.new
      )
      return Outcome.refused(resolved.refusal) unless resolved.resolved?

      selection = resolved.selection
      limits = selection.capabilities.limits
      budget = ContextAssembly::HistoryBudget.call(
        share: @command.history_token_budget_share || template.history_share, limits: limits
      )
      return Outcome.refused(budget.outcome) unless budget.accepted?

      # The estimate must model what the SEND will do: the caller's mode
      # wins, the kill-switch silences the default, the target row's default
      # otherwise — the exact rule the reply lane applies.
      mode = @command.reasoning_replay_mode
      mode ||= "none" if @command.conversation.reasoning_replay_downgraded_at
      assembled = ContextAssembly.assemble(
        conversation: @command.conversation,
        principal: principals.author,
        prompt: ContextAssembly::SpeakerEnvelope.for_author(
          principals.author, @command.conversation, @command.prompt, answerer: principals.answerer
        ),
        history_max_entries: @command.history_max_entries,
        history_token_budget: budget.value,
        profile: selection.execution_profile,
        limits: limits,
        reasoning: ContextAssembly::Replay.from_selection(selection, mode: mode),
        inline: @command.inline,
        declaring_profile: principals.declaring_profile,
        answerer: principals.answerer,
        # History's pictures placed as the send would place them; the
        # estimate's own prompt carries none.
        carries: ContextAssembly::AttachmentLine.carries_for(selection),
        template: template,
        variables: @command.variables,
        # The declaring profile's set: the estimate surface shows the skills
        # block the send would seal.
        tools: tools.definitions,
        environment: tools.environment
      )
      messages = assembled.messages
      normalized = ModelSelection::Workloads.normalize_workload_input(
        selection: selection, input: messages, uploads: assembled.uploads
      )
      return Outcome.refused(normalized.refusal) unless normalized.accepted?

      counted = ModelRequests::TokenCount.count(
        profile: selection.execution_profile,
        segments: Nexus::ModelRequestInput.text_segments(normalized.value.value)
      )
      return Outcome.refused(counted.refusal) unless counted.counted?

      # THE SAME BYTES: the payloads `ApplyNext#create_reply` hands the
      # seal (`InputEntries.for` over the normalized list), measured by the
      # seal's one measure. Never written here.
      entries = Nexus::InputEntries.for(normalized.value.value)
      Outcome.accepted(Estimate.new(
        input_tokens: counted.tokens,
        tokenizer_exact: counted.exact?,
        catalog_input_token_limit: limits.input_token_bound,
        advisory_input_token_limit: limits.advisory_input_bound,
        message_count: messages.length,
        selection: selection,
        history_selected: assembled.history.selected_count,
        history_skipped: assembled.history.skipped_count,
        history_skipped_reason: assembled.history.skipped_reason,
        history_compacted: assembled.history.compacted_count,
        rendered: Rendered.new(
          mechanism: mechanism, entries: entries, storage: ContentBodies::Measure.call(entries),
          blocks: assembled.blocks, memory: assembled.memory, slots: assembled.slots
        )
      ))
    end

    private

      # The order the compile runs under: the TRIAL template when the
      # caller sent one (validated here as the profile door validates the
      # column — the refusal names its path), else the addressee's own
      # under `assembly`, else the built-in order.
      def effective_template(principals)
        trial = @command.template
        return [principals.template, principals.prompt_mechanism, nil] if trial.nil?

        refusal = PromptTemplate.refusal(trial)
        return [nil, nil, Outcome.refused(:prompt_template_invalid, refusal)] if refusal

        [PromptTemplate.parse(trial), "assembly", nil]
      end
  end
end
