module CybrosAgent
  module Api
    # The InferenceRequest family's wire grammar. It reads STRICTLY where the server
    # guarantees a member and LENIENTLY where the server compacts one away —
    # the two are not a style choice, they are the contract: `inference_requests.json`
    # names a widest projection and a required subset for every compacted
    # envelope, and these maps are the required subset in code.
    module InferenceRequestProjections
      include WorkspaceProjections

      INFERENCE_REQUEST_SUMMARY = {
        public_id: :string,
        workload: :string,
        status: :string,
        model: [:shape, InferenceRequestModel],
        billing_subject: :optional_string,
        created_at: :string,
        updated_at: :string,
      }.freeze

      SHAPES = {
        InferenceRequestInputEstimate => {
          input_tokens: :integer,
          tokenizer_exact: :boolean,
          catalog_input_token_limit: :optional_integer,
          advisory_input_token_limit: :optional_integer,
          model: [:shape, InferenceRequestModel],
        },
        InferenceRequestSummary => INFERENCE_REQUEST_SUMMARY,
        InferenceRequest => INFERENCE_REQUEST_SUMMARY.merge(
          usage_summary: [:shape, InferenceRequestUsageSummary],
          # ABSENT IS THE SIGNAL, so this is the one member read by presence
          # rather than by type: no result means the run is not finished.
          result: [:optional_shape, InferenceRequestResult]
        ),
        InferenceRequestModel => { provider_id: :string, model_ref: :string, reasoning_effort: :optional_string,
          reasoning_enabled: :optional_boolean },
        InferenceRequestResult => {
          status: :string,
          finish_quality: :optional_string,
          # Beside a declined finish alone, and absent when the provider
          # named no category.
          refusal_category: :optional_string,
          # A failed run produced no text, and so renders none.
          output_text: :optional_string,
          usage: [:optional_shape, InferenceRequestUsage],
          # Timing compacts to nothing when neither number was measured, and
          # then the member itself is gone.
          timing: [:optional_shape, InferenceRequestTiming],
          error: [:optional_shape, InferenceRequestError],
          reasoning: [:optional_shape, InferenceRequestReasoning],
          # Absent for every workload that produces no bytes; `files` on the
          # value is what a caller iterates.
          output_files: [:optional_shapes, InferenceRequestFile],
          # Present on the embedding workload alone (C-U2).
          embeddings: [:optional_shapes, InferenceRequestEmbedding],
          # Present only on a run the creator's fallback ran again.
          model_change: [:optional_shape, InferenceRequestModelChange],
        },
        InferenceRequestEmbedding => { index: :integer, vector: :numbers },
        InferenceRequestModelChange => { from: :string, to: :string, reason: :string, category: :optional_string },
        InferenceRequestFile => { index: :integer, filename: :string, content_type: :string, byte_size: :integer },
        # Only the receipt's id and the cost-completeness flag are
        # guaranteed; every counter is a provider's choice to report or not.
        InferenceRequestUsage => {
          usage_record_public_id: :string,
          input_tokens: :optional_integer,
          cache_read_tokens: :optional_integer,
          uncached_input_tokens: :optional_integer,
          cache_creation_tokens: :optional_integer,
          cache_hit_rate: :optional_number,
          output_tokens: :optional_integer,
          reasoning_tokens: :optional_integer,
          total_tokens: :optional_integer,
          # A decimal string, never a Float: money does not survive binary
          # floating point, and the server sends the digits it stored.
          cost_amount: :optional_string,
          cost_unit: :optional_string,
          cost_complete: :boolean,
        },
        # The summary's counters default to zero rather than to nil, so
        # only the ratio can be missing — and it is missing exactly when
        # there is no input to take a ratio of.
        InferenceRequestUsageSummary => {
          request_count: :integer,
          input_tokens: :integer,
          cache_read_tokens: :integer,
          uncached_input_tokens: :integer,
          cache_creation_tokens: :integer,
          cache_hit_rate: :optional_number,
          output_tokens: :integer,
          reasoning_tokens: :integer,
          total_tokens: :integer,
          cost_amount: :string,
          cost_complete: :boolean,
        },
        InferenceRequestTiming => { duration_ms: :optional_integer, time_to_first_token_ms: :optional_integer },
        # `code` is always what the provider said, even when this side's
        # retry policy is what ended the run — "retry later" and "fix your
        # request" are the two answers a failed turn has to tell apart. The
        # budget rides beside it as a caveat, PRESENT ONLY WHEN IT APPLIES
        # like `finish_quality`, so its absence reads as false.
        InferenceRequestError => { code: :string, attempt_budget_spent: :flag },
        InferenceRequestReasoning => { available: :boolean, text: :optional_string },
        InferenceRequestEventPage => {
          items: [:shapes, InferenceRequestEvent, "events"],
          next_after: [:nullable_string, "pagination", "next_after"],
          watermark: [:integer, "pagination", "watermark"],
        },
        InferenceRequestEvent => {
          public_id: :string,
          sequence: :integer,
          cursor: :string,
          type: :string,
          resource_type: [:string, "resource", "type"],
          resource_public_id: [:string, "resource", "public_id"],
          occurred_at: :string,
          # Opaque JSON belonging to `type` — snapshotted so a caller
          # holding an event cannot mutate it into disagreeing with the
          # server, and NOT required to be an object.
          payload: :json,
        },
      }.freeze
    end
  end
end
