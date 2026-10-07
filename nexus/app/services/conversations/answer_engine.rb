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

    def selection(conversation, addressee: nil)
      own = own_selection(addressee)
      return own if own

      turn = last_reply(conversation, addressee) || last_reply(conversation, nil)
      variant = turn&.active_variant
      return nil if variant.nil?

      model = AgentRuns::CurrentModel.for_variant(variant)
      Selection.new(provider_id: model.provider_id, model_ref: model.model_ref,
        reasoning_effort: model.reasoning_effort, reasoning_enabled: model.reasoning_enabled)
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
      scope = conversation.conversation_turns.live
        .where(kind: "direct_reply")
        .joins(:active_variant)
        .where.not(conversation_turn_variants: { provider_id: nil })
      scope = scope.where(answering_user_id: addressee.id) if addressee
      scope.order(position: :desc).first
    end
  end
end
