module CybrosAgent
  module Api
    # Typed projections of a Workspace's OneShots — one direct model call.
    #
    # TERMINALITY IS READ FROM `result`, NEVER FROM A STATUS LIST. Nexus emits
    # the result envelope if and only if the run is finished and says so in the
    # contract; a client matching a frozen set of status strings would poll a
    # status it predates forever. So `status` is carried through verbatim,
    # unknown values included, and `finished?` asks the question the server
    # actually answers.
    #
    # Every counter is nullable because every provider reports a different
    # subset — the wire compacts what it has no number for, and these objects
    # carry that as nil rather than inventing a zero.

    OneShotModel = Data.define(:provider_id, :model_ref, :reasoning_effort)

    # A local, pre-create estimate for client-side compaction decisions. The
    # Provider remains authoritative; `tokenizer_exact` only says whether the
    # selected profile's declared tokenizer counted the estimate's text.
    OneShotInputEstimate = Data.define(
      :input_tokens, :tokenizer_exact, :catalog_input_token_limit,
      :advisory_input_token_limit, :model
    ) do
      def tokenizer_exact? = tokenizer_exact
    end

    # The terminal attempt's own receipt. `cost_complete` is the honest flag:
    # false means the amount below is not the whole story, not that it is zero.
    OneShotUsage = Data.define(
      :usage_record_public_id, :input_tokens, :cache_read_tokens,
      :uncached_input_tokens, :cache_creation_tokens, :cache_hit_rate,
      :output_tokens, :reasoning_tokens, :total_tokens,
      :cost_amount, :cost_unit, :cost_complete
    ) do
      def to_h = super.compact
    end

    # The CUMULATIVE cache across the whole attempt history, retries included,
    # where the usage above is one attempt's receipt. Always present: zero
    # requests is a true statement, not an absence.
    OneShotUsageSummary = Data.define(
      :request_count, :input_tokens, :cache_read_tokens, :uncached_input_tokens,
      :cache_creation_tokens, :cache_hit_rate, :output_tokens, :reasoning_tokens,
      :total_tokens, :cost_amount, :cost_complete
    )

    # One file a non-text workload produced. `index` is its address on the
    # download route and nothing else — the files carry no identifier of their
    # own, so the ordinal IS the name, and it is only meaningful inside the
    # OneShot that made it.
    OneShotFile = Data.define(:index, :filename, :content_type, :byte_size) do
      def to_h = super.compact
    end

    OneShotTiming = Data.define(:duration_ms, :time_to_first_token_ms) do
      def to_h = super.compact
    end
    # `code` names what the provider said. `attempt_budget_spent` says this
    # side's retry policy is what ended the run — a caveat beside the code,
    # never instead of it.
    OneShotError = Data.define(:code, :attempt_budget_spent) do
      def to_h = super.compact
    end
    OneShotReasoning = Data.define(:available, :text) do
      def to_h = super.compact
    end

    # ONE VECTOR of an embedding run (C-U2): `index` is the provider's
    # ordinal for the input it embeds, `vector` its numbers.
    OneShotEmbedding = Data.define(:index, :vector)

    # What a run's latest execution replaced when the creator's declared
    # fallback ran a declined run again: the two models as catalog refs, the
    # reason (`model_refused`), and the provider's category — nil when it
    # named none.
    OneShotModelChange = Data.define(:from, :to, :reason, :category) do
      def initialize(category: nil, **) = super

      def to_h = super.compact
    end

    # `finish_quality` is a SIBLING of status, never a member of `error`: a
    # cut-off answer is a success with a caveat, and the text it did produce
    # was produced and billed. nil means the run finished cleanly. A DECLINED
    # answer (`refused` by a provider's classifier, `blocked` by a content
    # stop) rides the same slot but FAILED the run — `error.code` is
    # `model_refused`, there is no text, and `refusal_category` is the
    # provider's own word for why, nil when it named none.
    # `embeddings` is the embedding workload's typed answer, and
    # `output_text` is nil there — the vectors are not prose. `model_change`
    # is present when the run's creator's declared fallback ran a declined
    # run again: every other member is then the fallback's execution.
    OneShotResult = Data.define(
      :status, :finish_quality, :output_text, :usage, :timing, :error, :reasoning, :output_files,
      :embeddings, :refusal_category, :model_change
    ) do
      def initialize(embeddings: nil, refusal_category: nil, model_change: nil, **) = super

      def truncated? = %w[output_budget_exhausted context_window_exhausted].include?(finish_quality)
      def refused? = %w[refused blocked].include?(finish_quality)
      def failed? = !error.nil?

      def to_h
        super.merge(
          usage: usage&.to_h,
          timing: timing&.to_h,
          error: error&.to_h,
          reasoning: reasoning&.to_h,
          output_files: output_files&.map(&:to_h),
          embeddings: embeddings&.map(&:to_h),
          model_change: model_change&.to_h
        ).compact
      end

      # Empty rather than nil for a workload that produces none, so a caller
      # can iterate without asking first. The WIRE omits the member entirely —
      # that is the server keeping a text caller from having to know it exists,
      # and this is the client turning it into the one shape worth having.
      def files = output_files || []

      # The numbers alone, in the provider's order; empty where none.
      def vectors = (embeddings || []).map(&:vector)
    end

    # The Basic type, which appears only inside a list. It cannot answer
    # `finished?` — the list projection carries no result envelope — and
    # deliberately has no such method rather than a guess.
    OneShotSummary = Data.define(
      :public_id, :workload, :status, :model, :billing_subject,
      :created_at, :updated_at
    )

    OneShot = Data.define(
      :public_id, :workload, :status, :model, :billing_subject,
      :created_at, :updated_at, :usage_summary, :result
    ) do
      # The server's own terminality signal (contract `terminality_signal`).
      def finished? = !result.nil?

      def output_text = result&.output_text
    end

    # ONE PAGE OF A REPLAY STREAM, which needs a member no other list does.
    #
    # `next_after` says where this page stopped. `watermark` says where the
    # STREAM was when the request was served — and a follower draining a run
    # that is still producing terminates on the second, not the first. Without
    # it the only stopping rule is "a page came back short", which is a moving
    # target on a live stream. It is present even on an empty page, where it
    # is needed most.
    # It is a SEQUENCE and `next_after` is a cursor, and the difference is the
    # point: sequences exist to be compared, cursors to be handed back.
    OneShotEventPage = Data.define(:items, :next_after, :watermark) do
      # Everything up to the head this page was served against has been seen.
      def caught_up?(applied_sequence)
        applied_sequence >= watermark
      end
    end

    # One durable item in a OneShot's replay stream.
    #
    # THE TWO ORDERED VALUES DO DIFFERENT JOBS. `sequence` is OneShot-local,
    # starts at 1 and is contiguous — it is what a follower orders and merges
    # by, and how it detects that it missed something. `cursor` is OPAQUE and
    # exists only to be handed back to a replay read; a consumer that decodes
    # it has invented a contract nobody promised, which is the mistake the
    # sequence is published to make unnecessary.
    #
    # `payload` is opaque JSON whose shape belongs to `type`, and a type this
    # gem predates arrives intact rather than as an exception.
    OneShotEvent = Data.define(
      :public_id, :sequence, :cursor, :type, :resource_type, :resource_public_id,
      :occurred_at, :payload
    )
  end
end
