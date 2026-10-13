module AgentRuns
  # All execution owners consume the same captured recovery policy. Each
  # switch leaves the prior invocation sealed and advances by history.
  module ModelFallback
    REFUSED = ModelInvocation::DECLINED_KEY
    OVERLOADED = ModelInvocation::OVERLOADED_KEY
    SWITCH_REASONS = [REFUSED, *ModelInvocation::RECOVERY_FAILURE_KEYS, *ModelInvocation::AVAILABILITY_KEYS].freeze
    FOREIGN_TOOL_HISTORY = "foreign_tool_history".freeze

    Candidate = Data.define(:provider_id, :model_ref, :reasoning_effort, :reasoning_enabled, :reason, :category) do
      def initialize(category: nil, reasoning_enabled: nil, **) = super

      def reference = "#{provider_id}/#{model_ref}"
      def attributes = to_h.except(:reason, :category)

      # The provider's category rides a refusal's switch as a fact, absent
      # when it named none and on the unavailable trigger.
      def narration(previous)
        { "model_change" => { "from" => previous, "to" => reference, "reason" => reason.to_s,
                              "category" => category }.compact }
      end

      # The ROW fact: the narration's block without `to`, which the row's
      # own selection says.
      def row_fact(previous) = { "model_change" => narration(previous).fetch("model_change").except("to") }
    end

    # A recovery switch has no stand; otherwise the sentence names the
    # terminal disposition and any unavailable candidate or refusal word.
    Verdict = Data.define(:stand, :fallback, :word) do
      def initialize(stand:, fallback: nil, word: nil) = super

      def switched? = stand.nil?
    end

    module_function

    def reason_of(invocation) = invocation.refused? ? REFUSED : invocation.failure_reason_key

    def switch_causes_of(node)
      keys = (0..node.execution_generation).map { |generation| "agent_run_task:#{node.id}:#{generation}" }
      scope = ModelInvocation.where(account_id: node.account_id, internal_creation_key: keys)
      scope.where(finish_quality: SimpleInference::FinishQuality::REFUSED)
        .or(scope.where(failure_reason_key: SWITCH_REASONS)).order(:id).to_a
    end

    def spent_route?(node, reference)
      return false if node.execution_generation.zero?

      switch_causes_of(node).any? do |invocation|
        (invocation.refused? || invocation.transient_exhausted?) &&
          "#{invocation.provider_id}/#{invocation.model_ref}" == reference
      end
    end

    def recover(account:, workload:, current:, owner:, configuration:, excluded: [], request_body: nil,
                include_current: false, &accept_candidate)
      ModelSelection::Recovery.resolve(account: account, workload: workload,
        submitted: Nexus::SubmittedModelSelection.new(model: "#{current.provider_id}/#{current.model_ref}",
          reasoning_effort: current.reasoning_effort, reasoning_enabled: current.reasoning_enabled),
        model_selection: owner.model_selection, fallback_models: owner.fallback_models,
        configuration: InferenceRequests::CoerceConfiguration.call(configuration), excluded: excluded,
        request_body: request_body, include_current: include_current,
        &accept_candidate)
    end

    def from_selection(selection, reason:, category: nil)
      Candidate.new(provider_id: selection.provider_id, model_ref: selection.model_ref,
        reasoning_effort: selection.reasoning.effort, reasoning_enabled: selection.reasoning.enabled,
        reason: reason, category: category)
    end

    def switch_for(agent_run:, node:, invocation:)
      return Verdict.new(stand: :abandoned) if agent_run.canceling? || agent_run.tombstoned?

      causes = switch_causes_of(node)
      result = recover(account: agent_run.account, workload: "text_generation", current: node, owner: node,
        configuration: node.request_options,
        excluded: causes.map { |row| "#{row.provider_id}/#{row.model_ref}" },
        request_body: invocation.content_bodies.find_by(role: "request")) do |selection|
        ModelSelection::Recovery.tools_refusal(selection, node.tool_definitions)
      end
      record_skips(node, result.skips)
      unless result.resolved?
        skipped = result.skips.last
        return Verdict.new(stand: :fallback_unavailable, fallback: skipped.fetch("model"), word: skipped.fetch("reason")) if skipped

        return Verdict.new(stand: node.fallback_models.empty? ? :no_fallback : :fallback_exhausted,
          word: result.refusal.to_s)
      end

      candidate = from_selection(result.selection, reason: reason_of(invocation), category: invocation.refusal_category)
      switch(agent_run, node, candidate) ? Verdict.new(stand: nil) : Verdict.new(stand: :abandoned)
    end

    def record_skips(node, skips)
      return if skips.empty?

      summary = node.output_summary.merge("model_skips" => Array(node.output_summary["model_skips"]) + skips)
      Transition.node(node, output_summary: summary, narration: { "model_skips" => skips })
    end

    # A lane that needs the tool loop's reasoning back (the row's
    # `reasoning_replay.required_for_tool_rounds`: the vendor refuses a
    # tool round of the turn in progress sent back without its reasoning)
    # cannot take a request with a call after its last user message, since
    # a switched-to model produced none of them and reads none of their
    # reasoning. An earlier turn's rounds go back without it (the
    # replay-quality live check, 2026-09-28: Kimi K3 and DeepSeek answered
    # 200 with earlier turns' reasoning dropped, and DeepSeek after Kimi's
    # tool turn). An unsigned call names no model, so every call counts.
    def takes_tool_history?(selection, request_body)
      return true unless selection.capabilities.reasoning_replay.required_for_tool_rounds
      return true if request_body.nil?

      payloads = request_body.entry_payloads
      turn = payloads.rindex { |payload| payload["role"] == "user" } || -1
      payloads.drop(turn + 1).none? { |payload| payload["type"] == "tool_call_item" }
    end

    # THE CALLER'S OWN PARAMETERS off a declined call's sealed options. A
    # call seals its model's RESOLVED parameters, that model's catalog
    # defaults included; the fallback asks under what the caller chose —
    # every value that differs from those defaults — and its own defaults
    # for the rest, as a loop step does under its submitted configuration:
    # one model's defaults carried to another would refuse every fallback
    # whose parameter vocabulary differs. A declining model the catalog no
    # longer resolves leaves the whole set for the fallback to judge.
    def chosen_configuration(invocation)
      sealed = invocation.request_options.except("instructions", Nexus::PromptCache::RequestKind::FACT)
      declining = ModelSelection.resolve(
        account: invocation.account, workload: invocation.workload,
        submitted: Nexus::SubmittedModelSelection.new(
          model: "#{invocation.provider_id}/#{invocation.model_ref}", reasoning_effort: invocation.reasoning_effort,
          reasoning_enabled: invocation.reasoning_enabled
        ),
        configuration: {}, port: ModelSelection::Resolver.new
      )
      return sealed unless declining.resolved?

      defaults = declining.selection.generation_config.to_h
      sealed.reject { |name, value| defaults[name] == value }
    end

    # ONE write for both triggers: the requeue under a fresh generation on
    # the new trio, the row fact — a new execution starts its own summary,
    # saying what it replaced — the narration, and the log line.
    def switch(agent_run, node, selected)
      return false if agent_run.canceling? || agent_run.tombstoned?

      previous = "#{node.provider_id}/#{node.model_ref}"
      Transition.node(node,
        status: "queued", execution_generation: node.execution_generation + 1, started_at: nil,
        output_summary: row_fact(node, selected, previous).merge(node.output_summary.slice("model_skips")), **selected.attributes,
        narration: selected.narration(previous))
      log_switch("loop=#{agent_run.public_id} task=#{node.node_key}", previous, selected)
      true
    end

    # The row holds ONE switch, and a refusal or overload the fallback
    # served is the one it keeps: the trace reads rows, and a served step
    # whose row lost its cause would count as the failing model's success.
    # So a later unavailable switch of the same step (a mail loop's fallback
    # whose credential is gone) keeps the cause's fact and narrates its own
    # on the feed alone; the feed's `task_status` items are the whole history.
    def row_fact(node, selected, previous)
      if SWITCH_REASONS.include?(node.output_summary.dig("model_change", "reason"))
        node.output_summary.slice("model_change")
      else
        selected.row_fact(previous)
      end
    end

    # The switch's one log line, on every lane that switches (`subject`
    # names where: a loop's task, a conversation's turn) — a refusal is a
    # 200 error-rate monitoring never sees. Written once the switch
    # committed: a converger retrying a failed apply must not log a switch
    # that rolled back.
    def log_switch(subject, previous, selected)
      category = ModelInvocations::LogField.token(selected.category).presence
      ApplicationRecord.current_transaction.after_commit do
        Rails.logger.info("event=model_fallback #{subject} from=#{previous} to=#{selected.reference} " \
                          "reason=#{selected.reason}#{" category=#{category}" if category}")
      end
    end
  end
end
