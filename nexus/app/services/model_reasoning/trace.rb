module ModelReasoning
  # One captured provenance envelope, read back for the replay ladder.
  Trace = Data.define(:envelope) do
    def origin_provider_id = envelope["origin_provider_id"]

    def origin_model_id = envelope["origin_model_id"]

    def origin_format_variant = envelope["origin_format_variant"]

    def items = Array(envelope["items"])

    # The answer's own output items at their places in the walk — its
    # messages and its calls — which place a replay and are never replayed
    # as reasoning.
    def markers = items.select { |item| marker?(item) }

    def message_markers = markers.select { |item| item["kind"] == TraceBuilder::ASSISTANT_MESSAGE }

    def call_markers = markers.select { |item| item["kind"] == TraceBuilder::TOOL_CALL }

    # The reasoning material a replay carries and prices: everything that is
    # not a marker. An envelope can exist without any — it may hold only the
    # answer's markers and the provider's verdict on the replayed history.
    def reasoning_items = items.reject { |item| marker?(item) }

    # The calls the provider bound a signature to (Gemini's thoughtSignature):
    # native material that rides its call even when no thought does.
    def signed_calls = call_markers.select { |item| item["provider_payload"] }

    # Whether a replay has anything to carry, so eligibility reads this and
    # never the trace's presence.
    def replay_material? = reasoning_items.any? || signed_calls.any?

    # The answer's label on a wire that states one: the last message's
    # phase, since a folded answer ends with its final words. Nil elsewhere.
    def assistant_phase = message_markers.last&.dig("phase")

    def native_origin
      { "provider_id" => origin_provider_id,
        "model_id" => origin_model_id,
        "api_format" => envelope["origin_api_format"] }
    end

    private

      def marker?(item) = TraceBuilder::MARKER_KINDS.include?(item["kind"])
  end
end
