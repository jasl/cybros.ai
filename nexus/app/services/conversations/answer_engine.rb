module Conversations
  # WHOSE ENGINE ANSWERS AN ADDRESSED TURN.
  # A row addressed AWAY from a conversation's default
  # answerer — a group turn — and every row a peer SENT (a `send`, the
  # spawn brief) carry the initiator's model words, and the addressee may
  # have a word of its own. So the turn runs on the engine that answers
  # for that addressee, in ONE order:
  #
  #   0. the addressee's OWN `default_model` — the profile fact its
  #      application declared (the agent's preset, at the model's own
  #      reasoning default);
  #   1. else the addressee's last reply turn's model selection in this
  #      conversation;
  #   2. else the conversation's last reply turn's;
  #   3. else nil — the caller's own: the row's submitted model, THE
  #      INITIATOR'S on a `send` or a brief (its named `model`, else the
  #      round it ran in).
  #
  # The kernel stores the fact and carries the initiator's model; it
  # chooses nothing. Only reply turns with a
  # model count: a message turn names none and the kernel's summary turn
  # ran the summarizer's. The conversation's own rows (its default
  # answerer's, posted as itself) and the kernel's mail never come here —
  # every 1:1 lane and every receipt keeps the selection it carries.
  module AnswerEngine
    Selection = Data.define(:provider_id, :model_ref, :reasoning_effort, :reasoning_enabled)

    module_function

    def applies?(conversation, addressee:, sent: false)
      addressee.id != conversation.answering_user_id || sent
    end

    def selection(conversation, addressee: nil)
      return captured_selection(conversation, addressee: addressee) if captured_model?(conversation, addressee: addressee)

      own = own_selection(addressee)
      return own if own

      turn = last_reply(conversation, addressee) || last_reply(conversation, nil)
      variant = turn&.active_variant
      return nil if variant.nil?

      model = Runs::CurrentModel.for_variant(variant)
      Selection.new(provider_id: model.provider_id, model_ref: model.model_ref,
        reasoning_effort: model.reasoning_effort, reasoning_enabled: model.reasoning_enabled)
    end

    def captured?(conversation, addressee: nil)
      conversation.agent_configuration && (addressee.nil? || addressee.id == conversation.answering_user_id)
    end

    # Identity-based children also capture configuration for executor contexts.
    # Only a captured selection intent replaces the ordinary addressee model ladder.
    def captured_model?(conversation, addressee: nil)
      captured?(conversation, addressee: addressee) && conversation.model_selection.present?
    end

    # A declared child continues its own actual selection, including a recovery
    # switch, while the configuration it was born with remains unchanged.
    def captured_selection(conversation, addressee: nil)
      variant = (last_reply(conversation, addressee) || last_reply(conversation, nil))&.active_variant
      return own_selection(conversation.agent_configuration) unless variant

      model = Runs::CurrentModel.for_variant(variant)
      Selection.new(provider_id: model.provider_id, model_ref: model.model_ref,
        reasoning_effort: model.reasoning_effort, reasoning_enabled: model.reasoning_enabled)
    end

    def captured_intent(conversation, addressee: nil)
      return unless captured_model?(conversation, addressee: addressee)

      variant = (last_reply(conversation, addressee) || last_reply(conversation, nil))&.active_variant
      variant&.model_selection || conversation.model_selection
    end

    # Preview and materialization resolve the captured intent and ordered
    # alternatives against live availability. Explicit model/provider
    # constraints remain independent of the profile's configured default.
    def resolve(account:, submitted:, configuration:, model_selection: nil, fallback_models: [], &candidate_check)
      return ModelSelection.resolve(account: account, workload: "text_generation",
        submitted: submitted, configuration: configuration, port: ModelSelection::Resolver.new) if model_selection.nil?

      ModelSelection::Recovery.resolve(account: account, workload: "text_generation",
        submitted: submitted, configuration: configuration, model_selection: model_selection,
        fallback_models: fallback_models, &candidate_check)
    end

    # Step 0: the profile fact, a catalog ref the declaration judged.
    def own_selection(addressee)
      ref = addressee&.default_model
      return nil if ref.blank?

      parsed = Nexus::ModelRef.parse(ref)
      Selection.new(provider_id: parsed.provider_id, model_ref: parsed.model_ref,
        reasoning_effort: nil, reasoning_enabled: nil)
    end

    def last_reply(conversation, addressee)
      scope = conversation.turns.live
        .where(kind: "direct_reply")
        .joins(:active_variant)
        .where.not(variants: { provider_id: nil })
      scope = scope.where(answering_user_id: addressee.id) if addressee
      scope.order(position: :desc).first
    end
  end
end
