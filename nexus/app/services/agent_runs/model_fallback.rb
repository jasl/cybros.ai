module AgentRuns
  # AN AUTOMATIC MODEL SWITCH THE ANSWERER'S PROFILE DECLARED, two triggers
  # and one write. A result receipt whose captured model is unavailable
  # moves once per mail loop to that recipient's current different
  # `default_model` (the loop's own allowance, never renewed, and never for
  # an explicitly selected branch); a step a provider's classifier REFUSED,
  # or one the provider was OVERLOADED for on every attempt of its budget,
  # moves once per step to the answerer's `fallback_model`, resolved against
  # the step's own request before the switch. Both are bounded by the step's
  # own history — neither ever returns it to a model that refused it or was
  # overloaded for it — and both read the declaration live from the
  # answerer's profile. The kernel reads a declared ref and chooses nothing;
  # the refused or failed invocation stays sealed as evidence of the
  # execution it replaced. A tool-less direct reply and a one-shot have no
  # step to requeue: their convergers read the same `candidate` and ask
  # again on it — the reply as the kernel's own regeneration
  # (`Conversations::Turns::Regenerate.fallback`), the one-shot as its
  # second execution (`InferenceRequests::Fallback`).
  module ModelFallback
    # The mail rung's trigger words. An overload stands here too, so a mail
    # round whose answerer declares no fallback still takes its own rung.
    UNAVAILABLE = %w[
      unknown_provider unknown_model model_hidden provider_disabled missing_credential
      reauthorization_required credential_unusable provider_model_unavailable
      attempt_budget_spent provider_overloaded
    ].freeze
    # The switch trigger's reasons: the declined or overloaded step's own
    # failure key, so a switch and a stand name the same fact.
    REFUSED = ModelInvocation::DECLINED_KEY
    OVERLOADED = ModelInvocation::OVERLOADED_KEY
    SWITCH_REASONS = [REFUSED, OVERLOADED].freeze
    # A fallback that needs every tool round's reasoning back cannot take a
    # history of tool rounds it did not produce.
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

    # What a declined or overloaded step comes to: a switch (no stand), or
    # the stand the kernel's sentence names — `fallback` and `word` beside
    # `fallback_unavailable`, the `earlier` switch-cause invocation beside
    # `already_switched`.
    Verdict = Data.define(:stand, :fallback, :word, :earlier) do
      def initialize(stand:, fallback: nil, word: nil, earlier: nil) = super

      def switched? = stand.nil?
    end

    module_function

    # The declared ref per trigger — `:unavailable` the answerer's
    # `default_model` on the mail rung's words, `:switch` its
    # `fallback_model` on a refusal or an overload — that differs from the
    # current selection and was not a switch cause of this step (`excluded`);
    # effort nil — a profile's ref names a model, not the old model's
    # reasoning vocabulary, so the new model's own default resolves at its
    # next start. The trigger is the caller's, never inferred from the
    # reason: an overload is both a switch reason and a mail-rung word.
    def candidate(answerer:, current:, trigger:, reason:, category: nil, excluded: [])
      ref = case trigger
      when :unavailable then answerer.default_model if UNAVAILABLE.include?(reason.to_s)
      when :switch then answerer.fallback_model if SWITCH_REASONS.include?(reason.to_s)
      else raise ArgumentError, "unknown fallback trigger #{trigger.inspect}"
      end
      return if ref.blank? || ref == "#{current.provider_id}/#{current.model_ref}" || excluded.include?(ref)

      selected = Nexus::ModelRef.parse(ref)
      Candidate.new(provider_id: selected.provider_id, model_ref: selected.model_ref,
        reasoning_effort: nil, reason: reason, category: category)
    end

    # The switch reason an invocation's failure is.
    def reason_of(invocation) = invocation.refused? ? REFUSED : OVERLOADED

    # THE STEP'S OWN HISTORY, the once-per-step bound: the invocations of
    # this node a classifier refused or the provider was overloaded for,
    # oldest first — its generation-keyed rows, exact keys on the
    # account-scoped unique index. A person's retry adds a generation and
    # renews nothing.
    def switch_causes_of(node)
      keys = (0..node.execution_generation).map { |generation| "agent_run_task:#{node.id}:#{generation}" }
      scope = ModelInvocation.where(account_id: node.account_id, internal_creation_key: keys)
      scope.where(finish_quality: SimpleInference::FinishQuality::REFUSED)
        .or(scope.where(failure_reason_key: OVERLOADED)).order(:id).to_a
    end

    # The switch trigger, under the loop lock at terminal apply. It fires
    # only on the step's FIRST cause, and resolves the declared fallback
    # against the step's inherited request, so a fallback that cannot take
    # it is a stand naming the resolver's word rather than a start-time
    # failure that would hide the cause.
    def switch_for(agent_run:, node:, invocation:)
      causes = switch_causes_of(node)
      earlier = causes.find { |row| row.id != invocation.id }
      return Verdict.new(stand: :already_switched, earlier: earlier) if earlier

      answerer = agent_run.answering_user
      selected = candidate(answerer: answerer, current: node, trigger: :switch, reason: reason_of(invocation),
        category: invocation.refusal_category, excluded: causes.map { |row| "#{row.provider_id}/#{row.model_ref}" })
      if selected.nil?
        return Verdict.new(stand: answerer.fallback_model.present? ? :fallback_is_current : :no_fallback)
      end

      resolved = resolve(account: agent_run.account, workload: "text_generation", candidate: selected,
        configuration: node.request_options)
      unless resolved.resolved?
        return Verdict.new(stand: :fallback_unavailable, fallback: selected.reference, word: resolved.refusal.to_s)
      end
      unless takes_tool_history?(resolved.selection, invocation.content_bodies.find_by(role: "request"))
        return Verdict.new(stand: :fallback_unavailable, fallback: selected.reference, word: FOREIGN_TOOL_HISTORY)
      end

      switch(agent_run, node, selected) ? Verdict.new(stand: nil) : Verdict.new(stand: :abandoned)
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

    # The unavailable trigger, the mail rule: under the loop lock, at
    # selection refusal or terminal apply. Only the failed round is
    # requeued; its predecessor tools and the child that produced the
    # receipt remain settled.
    def call(agent_run:, node:, reason:)
      return false if agent_run.result_delivery_model_fallback_used? || agent_run.canceling? || agent_run.tombstoned?
      return false unless agent_run.kernel_result_delivery? && node.continuation_source == Tasks::Compile::ROUND

      excluded = switch_causes_of(node).map { |row| "#{row.provider_id}/#{row.model_ref}" }
      selected = candidate(answerer: agent_run.answering_user, current: node, trigger: :unavailable,
        reason: reason, excluded: excluded)
      return false unless selected

      agent_run.update!(result_delivery_model_fallback_used: true)
      switch(agent_run, node, selected)
    end

    # The one gate a switched execution meets again at its start: the
    # fallback against the caller's own options — a step's inherited ones,
    # a one-shot's `chosen_configuration` — at its own reasoning default.
    def resolve(account:, workload:, candidate:, configuration:)
      ModelSelection.resolve(
        account: account, workload: workload,
        submitted: Nexus::SubmittedModelSelection.new(model: candidate.reference, reasoning_effort: nil),
        configuration: InferenceRequests::CoerceConfiguration.call(configuration),
        port: ModelSelection::Resolver.new
      )
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
        output_summary: row_fact(node, selected, previous), **selected.attributes,
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
