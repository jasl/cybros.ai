# The assembly-intent body readers the reply lane's doors share (inputs,
# the estimate, regeneration): read from the parsed body, not the permit
# filter, which strips an unknown key and flattens an explicit null.
module AgentAPI::AssemblyIntents
  HISTORY_INTENT_KEYS = %w[max_entries token_budget_share].freeze

  private

    # Closed here: a non-hash or unknown key refuses, null or {} reads as
    # clear, absence as untouched (nil).
    def history_intent(envelope_key)
      envelope = Hash.try_convert(request.request_parameters[envelope_key.to_s])
      return nil unless envelope&.key?("history")

      history = envelope["history"]
      return {} if history.nil?

      history = Hash.try_convert(history)
      raise APIErrors::ParameterInvalid, :history if history.nil? ||
        (history.keys - HISTORY_INTENT_KEYS).any?

      intent = {}
      unless history["max_entries"].nil?
        # The candidate window bounds the per-reply body read, and the
        # vocabulary must not promise a read the posture refuses.
        intent["max_entries"] =
          bounded_integer(history["max_entries"], :max_entries, range: 0..200)
      end
      unless history["token_budget_share"].nil?
        intent["token_budget_share"] = bounded_share(history["token_budget_share"])
      end
      intent
    end

    # The replay-policy intent, body-read for the same reasons as history:
    # nil = absent, {} = explicit clear, else the validated {"mode" => …}.
    def reasoning_replay_intent(envelope_key)
      envelope = Hash.try_convert(request.request_parameters[envelope_key.to_s])
      return nil unless envelope&.key?("reasoning_replay")

      intent = envelope["reasoning_replay"]
      return {} if intent.nil?

      intent = Hash.try_convert(intent)
      raise APIErrors::ParameterInvalid, :reasoning_replay if intent.nil? ||
        (intent.keys - ["mode"]).any? ||
        !%w[none last_turn all].include?(intent["mode"].to_s)

      { "mode" => intent["mode"].to_s }
    end

    # The client's own inline text, body-read like its siblings: nil =
    # absent, [] (or null) = explicit clear, else the validated entries.
    def inline_intent(envelope_key)
      envelope = Hash.try_convert(request.request_parameters[envelope_key.to_s])
      return nil unless envelope&.key?("inline")

      raw = envelope["inline"]
      return [] if raw.nil?

      entries = Array.try_convert(raw)
      raise APIErrors::ParameterInvalid, :inline if entries.nil? ||
        entries.empty? || entries.length > ConversationInput::INLINE_LIMIT

      entries.map { |entry| inline_entry(entry) }
    end

    # The turn's values for the addressee's declared template names: an
    # object of strings, body-read like its siblings — the permit filter
    # would strip it without a word. nil = absent; the names and the
    # addressee's word are the model's to judge.
    def variables_intent(envelope_key)
      envelope = Hash.try_convert(request.request_parameters[envelope_key.to_s])
      return nil unless envelope&.key?("variables")

      variables = Hash.try_convert(envelope["variables"])
      raise APIErrors::ParameterInvalid, :variables if variables.nil?

      variables.transform_keys(&:to_s)
    end

    # The row's grammar, admitted at the boundary (two layers must agree):
    # `slot` xor `position`, `role` required only without a slot.
    def inline_entry(raw)
      entry = Hash.try_convert(raw)
      raise APIErrors::ParameterInvalid, :inline if entry.nil? ||
        (entry.keys - ConversationInput::INLINE_KEYS).any? ||
        !ConversationInput.inline_entry_addressed?(entry) ||
        !(entry["role"].nil? || ConversationInput::INLINE_ROLES.include?(entry["role"])) ||
        entry["text"].to_s.empty? ||
        !(entry["position"].nil? ||
          ConversationInput::INLINE_POSITIONS.include?(entry["position"]))

      { "slot" => entry["slot"], "role" => entry["role"], "text" => entry["text"].to_s,
        "position" => entry["position"] }.compact
    end

    # Six decimals keeps every accepted share inside the canonical digest's
    # decimal grammar; an exponent-form float would 422 the create receipt.
    def bounded_share(value)
      share = Float(value, exception: false)&.round(6)
      raise APIErrors::ParameterInvalid, :token_budget_share if
        share.nil? || share <= 0 || share > 1

      share
    end

    # The trio rides "provider/tail" — the OneShot submission grammar's
    # exact-model half. Selectors need a stored submitted string and wait
    # for their recorded round. The two fields are read by their wire
    # names — a permitted envelope and a raw request-body object both
    # answer them — so no caller re-keys its hash first.
    def split_model(model_fields)
      ref = Nexus::ModelRef.parse(model_fields&.dig("model"))
      [ref.provider_id.presence, ref.model_ref.presence, model_fields&.dig("reasoning_effort").presence]
    end
end
