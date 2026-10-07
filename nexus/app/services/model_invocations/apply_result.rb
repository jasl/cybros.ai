module ModelInvocations
  # Applies what the send came back with: transient failures requeue until the budget is
  # spent, the CAS under the invocation lock discards a late result against a cut row, every
  # exit writes the receipt.
  class ApplyResult
    APPLIED = :applied
    REQUEUED = :requeued
    # A cut or sweep terminalized the attempt while the provider was
    # answering. The late result is discarded; the first answer stands.
    DISCARDED = :discarded

    # The predecessor's transient set, verbatim (529 is Anthropic's overload).
    TRANSIENT_HTTP_STATUSES = [429, 500, 502, 503, 504, 529].freeze
    # The predecessor's default cooldown scale: 10s times the attempts spent.
    RETRY_COOLDOWN_STEP = 10

    # `provider_floor_at` is the lane's floor this apply raised from the
    # provider's `Retry-After`, nil when none: the terminal arm's admission
    # wake lands at it, so a budget spent on a 429 wakes the siblings when
    # the provider said, not now.
    Result = Data.define(:outcome, :attempt, :provider_floor_at) do
      def initialize(provider_floor_at: nil, **) = super

      def applied? = outcome == APPLIED
      def requeued? = outcome == REQUEUED
    end

    def self.call(...) = new(...).call

    # The one reading of the typed finish, shared with the execution
    # sequence that must know a declined answer BEFORE this applies it (the
    # stream's withdrawal is told while the row still runs). Only a text
    # generation carries the typed finish qualities the product exposes;
    # the protocol owns its typed finish spelling.
    def self.finish_quality(invocation:, outcome:)
      return nil unless outcome.succeeded? && invocation.workload == "text_generation"

      SimpleInference::FinishQuality.for(
        adapter_profile: outcome.profile.adapter_profile, detail: outcome.result&.finish_detail
      )
    end

    def self.declined?(invocation:, outcome:)
      SimpleInference::FinishQuality::DECLINED.include?(finish_quality(invocation: invocation, outcome: outcome))
    end

    def self.finish_error?(invocation:, outcome:)
      finish_quality(invocation: invocation, outcome: outcome) == SimpleInference::FinishQuality::ERROR
    end

    # Public so the execution sequence can pre-classify before this applies.
    # Every timeout and connection loss is transient (its ordinal still
    # spends budget); a provider that processed and failed is not.
    def self.transient_error?(error)
      case error
      when SimpleInference::HTTPError
        TRANSIENT_HTTP_STATUSES.include?(error.status.to_i)
      when SimpleInference::TimeoutError, SimpleInference::ConnectionError,
           SimpleInference::ProviderStreamInterruptedError
        true
      else
        false
      end
    end

    # `outcome` is the Dispatch::Result: the assembled family result on
    # success, the typed gem error otherwise.
    def initialize(attempt:, outcome:)
      @attempt = attempt
      @outcome = outcome
      @invocation = attempt.model_invocation
    end

    def call
      @outcome.succeeded? ? apply_success : apply_failure
    end

    private

      # Blob IO runs before the transaction, or an upload under the invocation
      # lock serializes every writer; every exit that did not attach purges.
      # An unstorable result fails the invocation rather than raising.
      def apply_success
        blobs = output_blobs
        attached = false

        applied = locked_apply do |now|
          refusal = binary_output_refusal(blobs) || write_answer_bodies
          if refusal
            @attempt.update!(status: "failed", terminal_at: now)
            @invocation.terminalize(status: "failed", reason_key: "result_unstorable")
            record_receipt(
              status: "failed", error_code: "result_unstorable", invocation_locked: true
            )
          else
            @invocation.output_files.attach(blobs) if blobs.any?
            attached = blobs.any?
            @attempt.update!(status: "completed", terminal_at: now)
            # The provider's words beside a declined finish: its category in
            # its own column, its sentence (display text, never parsed) in
            # the detail — each absent when the provider sent none.
            @invocation.terminalize(
              status: "completed", finish_quality: finish_quality,
              reason_key: (ModelInvocation::FINISH_ERROR_KEY if finish_error?),
              refusal_category: declined_refusal&.category,
              detail: finish_error? ? finish_error_detail : declined_refusal&.explanation
            )
            # A declined answer's receipt is `succeeded` too — the exchange
            # happened — and priced by the catalog's formula, though a
            # provider may bill some refusal categories at nothing: cost
            # arithmetic is approximate, and a readout wanting the true spend
            # joins receipts to the invocations' `finish_quality`.
            record_receipt(status: "succeeded", invocation_locked: true)
          end
        end
        if applied
          log_input_transformations
          log_declined
        else
          record_discarded
        end

        Result.new(outcome: applied ? APPLIED : DISCARDED, attempt: @attempt)
      ensure
        blobs.each(&:purge) if blobs && !attached
      end

      # A declined or errored generation has no usable answer: no calls, reasoning
      # or trace land on the row, so nothing clones, replays or presents its
      # partial output. A complete call block streamed ahead of the terminal
      # finish would otherwise replay as an unanswered pair in every later
      # turn. Returns the storage refusal, nil when stored or absent.
      def write_answer_bodies
        return nil if declined? || finish_error?

        refusal = write_response_body || write_reasoning_body || write_tool_calls_body
        # The trace sidecar is OPTIONAL replay material: its refusal must
        # never destroy the billed, successful answer it rides beside —
        # an unstorable trace just means that turn's replay degrades.
        write_reasoning_trace_body unless refusal
        refusal
      end

      def finish_quality
        return @finish_quality if defined?(@finish_quality)

        @finish_quality = self.class.finish_quality(invocation: @invocation, outcome: @outcome)
      end

      def declined? = SimpleInference::FinishQuality::DECLINED.include?(finish_quality)
      def finish_error? = finish_quality == SimpleInference::FinishQuality::ERROR

      # The validated finish word is diagnostic evidence, not a retry hint
      # or a refusal category. OTHER's cause remains unknown.
      def finish_error_detail
        "The provider ended generation with #{@outcome.result.finish_detail}; no complete answer was produced."
      end

      # The gem's typed Refusal, read only beside a declined finish: every
      # other finish carries none, and a lane with no refusal concept has no
      # member to read.
      def declined_refusal = (@outcome.result.refusal if declined?)

      # A refusal is an HTTP 200 that error-rate monitoring never sees, so it
      # is named — once, after the answer committed, and never for a
      # discarded loser. The category is the provider's closed word, bounded
      # like every provider field this apply logs, and absent when none came.
      def log_declined
        return unless declined?

        category = LogField.token(declined_refusal&.category).presence
        Rails.logger.info(
          "event=model_refused invocation=#{@invocation.public_id} " \
          "model=#{@invocation.provider_id}/#{@invocation.model_ref} quality=#{finish_quality}" \
          "#{" category=#{category}" if category}"
        )
      end

      # The provider's own answer as the Result carries it — the unary body,
      # or the message a stream assembled — for the facts the typed Result
      # has no member for.
      def provider_response_body
        Hash.try_convert(@outcome.result&.provider_response&.body) || {}
      end

      # THE SERVER'S VERDICT ON THE REPLAYED HISTORY: under a dropping thinking
      # binding the provider answers 200 and lists each block it dropped or
      # rewrote (`{type, path, reason}`); `[]` says the history replayed intact.
      # Nil when the provider reports nothing, or anything but a list — unknown,
      # never a claim. A list is kept verbatim, entries and all.
      def input_transformations = Array.try_convert(provider_response_body["input_transformations"])

      # One count line per answer that carries the verdict — `count=0` is the
      # intact round a readout looks for — and one warn line per entry. Its
      # fields are the provider's closed diagnostic words, never content, each
      # collapsed to one line and bounded so a hostile value costs its own tail
      # and never a second log line; an entry that is not an object is still an
      # entry, logged with no fields. This runs after the answer committed, so
      # nothing in it may raise past the apply. Only an applied answer logs: a
      # discarded loser's verdict is not the one that stands.
      def log_input_transformations
        entries = input_transformations
        return if entries.nil?

        Rails.logger.info(
          "event=provider_input_transformations invocation=#{@invocation.public_id} " \
          "ordinal=#{@attempt.ordinal} count=#{entries.length}"
        )
        entries.each do |entry|
          fields = Hash.try_convert(entry) || {}
          Rails.logger.warn(
            "event=provider_input_transformation invocation=#{@invocation.public_id} " \
            "ordinal=#{@attempt.ordinal} type=#{LogField.token(fields["type"])} " \
            "path=#{LogField.token(fields["path"])} reason=#{LogField.token(fields["reason"])}"
          )
        end
      end

      def apply_failure
        transient?(@outcome.error) ? requeue_transient : terminalize(failure_reason)
      end

      # The started-then-failed back edge: this ordinal is spent, and a
      # spent budget is the hard stop rather than a deferral.
      def requeue_transient
        requeued = nil
        applied = locked_apply do |now|
          @attempt.update!(status: "failed", terminal_at: now)
          record_receipt(
            status: "failed", error_code: failure_reason, invocation_locked: true
          )
          if AttemptOrdinal.budget_spent?(@invocation, ordinal: @attempt.ordinal)
            @invocation.terminalize(status: "failed", reason_key: spent_budget_key, detail: failure_detail)
            requeued = false
          else
            @invocation.update!(status: "queued", next_admission_at: now + cooldown_seconds)
            requeued = true
          end
          # LAST in the block: the implicit ON CONFLICT row lock's shortest
          # hold, after the invocation lock and the usage rows.
          raise_provider_floor(now)
        end
        unless applied
          record_discarded
          return Result.new(outcome: DISCARDED, attempt: @attempt)
        end

        Result.new(outcome: requeued ? REQUEUED : APPLIED, attempt: @attempt,
                   provider_floor_at: @provider_floor_at)
      end

      # THE PROVIDER'S FACT: a Retry-After on an overloaded answer names when
      # this LANE may be asked again — every queued invocation on it, not
      # this attempt alone. Never a computed backoff: no header, no floor.
      # Written last under the invocation lock, beside the disposition it
      # arrived with, so no admitter reads the requeue without it. Reached
      # from the transient set only: a header on a 400/401/403 is a header on
      # the caller's fault and would hold every sibling on the lane for up to
      # an hour.
      def raise_provider_floor(now)
        seconds = retry_after
        return if seconds.nil?

        @provider_floor_at = now + seconds
        ModelProviderRuntimeState.raise_floor(
          account_id: @invocation.account_id, provider_id: @invocation.provider_id, until_at: @provider_floor_at
        )
        Rails.logger.warn(
          "event=provider_floor_raised account=#{@invocation.account_id} provider=#{@invocation.provider_id} " \
          "until=#{@provider_floor_at.iso8601} retry_after_s=#{seconds} invocation=#{@invocation.public_id} " \
          "status=#{@outcome.error.status}"
        )
      end

      # A budget spent on the provider's overload, and on nothing else, is
      # its own key — consecutive overloads are the one transient failure a
      # declared fallback answers. Any other transient answer among the
      # spent attempts (a 504, a rate limit, a lost connection) leaves it
      # `attempt_budget_spent`: the receipts keep each attempt's own word.
      def spent_budget_key
        return "attempt_budget_spent" unless failure_reason == ModelInvocation::OVERLOADED_KEY

        others = UsageRecord.where(account_id: @invocation.account_id, model_invocation_public_id: @invocation.public_id,
          status: "failed").where.not(attempt_ordinal: @attempt.ordinal)
          .where("error_code IS DISTINCT FROM ?", ModelInvocation::OVERLOADED_KEY)
        others.exists? ? "attempt_budget_spent" : ModelInvocation::OVERLOADED_KEY
      end

      def terminalize(reason_key)
        applied = locked_apply do |now|
          @attempt.update!(status: "failed", terminal_at: now)
          @invocation.terminalize(status: "failed", reason_key: reason_key, detail: failure_detail)
          record_receipt(status: "failed", error_code: reason_key, invocation_locked: true)
        end
        record_discarded unless applied

        Result.new(outcome: applied ? APPLIED : DISCARDED, attempt: @attempt)
      end

      # Best-effort: an unrescued RecordInvalid would roll back the terminal
      # flip and discard a billed answer. An unwritten receipt leaves the
      # attempt settlement-pending for `CloseAbandonedSettlements`; server errors stay loud.
      def record_receipt(status:, error_code: nil, invocation_locked: false)
        UsageRecords::Record.call(
          attempt: @attempt, outcome: @outcome, status: status, error_code: error_code,
          invocation_locked: invocation_locked
        )
      rescue ActiveRecord::RecordInvalid, ActiveModel::RangeError => error
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "usage_record_unwritable", invocation: @invocation.public_id,
                     ordinal: @attempt.ordinal, status: status })
        nil
      end

      # The CAS-loss receipt: the disposition is `discarded`, and the
      # error_code keeps whatever the wire actually said underneath it.
      def record_discarded
        record_receipt(
          status: "discarded",
          error_code: @outcome.succeeded? ? nil : failure_reason
        )
      end

      # The invocation row is the serialization point every terminal writer
      # locks first. Both rows are rechecked: the cut leaves a started attempt
      # running under a terminal parent by design, and a 503 there must not requeue canceled work.
      def locked_apply
        ApplicationRecord.transaction do
          @invocation.lock!
          next false if @invocation.terminal?

          @attempt.reload
          next false unless @attempt.running?

          yield DatabaseClock.now
          true
        end
      end

      # ---- success evidence -------------------------------------------------

      # Absent text writes no body rather than an empty one. Returns the
      # refusal, nil when stored or absent: a bound refusal is the invocation
      # failing, never an exception a job retry would re-deliver.
      def write_response_body
        text = response_text
        return if text.nil?

        replace_body(role: "response", entries: Nexus::InputEntries.for(text))
      end

      def response_text
        result = @outcome.result
        case @invocation.workload
        when "text_generation" then result.output_text.presence
        when "transcription" then result.text.presence
        when "embedding" then JSON.generate(embedding_payload(result))
        when "image_generation" then result.output_text.presence
        else nil
        end
      end

      # Index + vector, nothing else; the gem normalized the shape at its
      # boundary, so only the missing-vector check remains.
      def embedding_payload(result)
        {
          "embeddings" => Array(result.embeddings).filter_map.with_index do |embedding, index|
            vector = embedding["embedding"]
            next if vector.nil?

            { "index" => embedding.fetch("index", index), "embedding" => vector }
          end,
        }
      end

      # Only reasoning text is retained here; an encrypted blob is
      # continuation material, not display evidence.
      def write_reasoning_body
        texts = reasoning_texts
        return if texts.empty?

        replace_body(role: "reasoning", entries: Nexus::InputEntries.for(texts.join("\n\n")))
      end

      # The gate is the workload, never a respond_to? probe. A Responses
      # lane emits reasoning as an item, a chat-completions lane on the
      # message (the gem folds its two spellings onto one key); both are read.
      def reasoning_texts
        return [] unless @invocation.workload == "text_generation"

        items = Array(@outcome.result.output_items)
          .select { |item| item["type"] == "reasoning" }
          .flat_map { |item| reasoning_item_texts(item) }
        return items unless items.empty?

        Array(chat_reasoning_text)
      end

      def chat_reasoning_text
        message = Hash(@outcome.result.assistant_message)
        # Both spellings: streamed turns normalize onto `reasoning_content`,
        # a UNARY OpenRouter body keeps `reasoning` — the one-place-read
        # lesson's second spelling.
        message["reasoning_content"].to_s.presence || message["reasoning"].to_s.presence
      end

      # The calls the model made, normalized once while both wire families
      # are in hand. Answer material, unlike the trace sidecar: unstorable
      # calls are an incomplete answer and refuse like the body.
      def write_tool_calls_body
        return unless @invocation.workload == "text_generation"

        @tool_calls_envelope = Nexus::ModelToolCalls.envelope(@outcome.result.tool_calls)
        return if @tool_calls_envelope.nil?

        replace_body(role: "tool_calls", entries: [@tool_calls_envelope])
      end

      # The native trace frozen at the only moment it exists, keyed by the
      # wire model id; replay material, never presented. Always nil: a
      # refused write drops the trace, never the invocation.
      def write_reasoning_trace_body
        return unless @invocation.workload == "text_generation"

        envelope = ModelReasoning::TraceBuilder.call(
          result: @outcome.result,
          normalized_tool_calls: @tool_calls_envelope&.fetch("items") || [],
          origin: {
            provider_id: @invocation.provider_id,
            model_id: @outcome.profile.model_pin,
            api_format: @outcome.profile.adapter_profile,
            invocation_id: @invocation.public_id,
          },
          input_transformations: input_transformations
        )
        return if envelope.nil?

        refusal = replace_body(role: "reasoning_trace", entries: [envelope])
        if refusal
          Rails.logger.warn(
            "event=reasoning_trace_dropped invocation=#{@invocation.public_id} " \
            "reason=#{refusal}"
          )
        end
        nil
      end

      def reasoning_item_texts(item)
        text = item["text"].to_s.presence
        return [text] if text

        (Array(item["summary"]) + Array(item["content"]))
          .filter_map { |part| part["text"].to_s.presence }
      end

      def replace_body(role:, entries:)
        result = ContentBodies::Replace.call(
          owner: @invocation, role: role, entries: entries, seal: true
        )
        result.accepted? ? nil : result.refusal
      end

      # The predecessor's blob shapes, kept: one blob per image output, one
      # per speech output, named by the invocation's public id.
      def output_blobs
        result = @outcome.result
        case @invocation.workload
        when "image_generation" then image_blobs(result)
        when "speech_generation" then Array(speech_blob(result))
        else []
        end
      end

      # Image and speech calls owe at least one byte-valid output. Per-image
      # decoding is tolerant so a bad optional sibling cannot cost good ones;
      # an entirely unusable binary result is not a successful invocation.
      def binary_output_refusal(blobs)
        return unless %w[image_generation speech_generation].include?(@invocation.workload)
        return unless blobs.empty?

        :result_unstorable
      end

      # Decoded once per image under a rescue: RFC 2045 whitespace is valid
      # on the wire, one corrupt image costs that image and never the apply,
      # and the cap bounds what one item may make this process hold.
      MAX_IMAGE_OUTPUT_BYTES = 25 * 1024 * 1024

      def image_blobs(result)
        blobs = []
        Array(result.images).each_with_index do |image, index|
          blob = image_blob(image, index)
          blobs << blob unless blob.nil?
        end
        blobs
      rescue StandardError
        # `create_and_upload!` returns each staged blob independently. If a
        # later sibling raises, the outer assignment never receives this
        # partial array, so its ensure cannot see what must be purged.
        blobs.each(&:purge)
        raise
      end

      def image_blob(image, index)
        encoded = image["b64_json"].to_s.presence
        return if encoded.nil?

        # RFC 2045 whitespace is valid; after removing it, strict decode makes
        # malformed provider output a per-item miss instead of an uploaded
        # garbage blob. This remains the one decode of the payload.
        bytes = encoded.delete(" \t\r\n").unpack1("m0")
        return if bytes.empty? || bytes.bytesize > MAX_IMAGE_OUTPUT_BYTES
        content_type = SimpleInference::MediaType.detect(bytes)
        return unless SimpleInference::MediaType::IMAGE_TYPES.include?(content_type)

        ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes),
          filename: "#{@invocation.public_id}-image-output-#{index + 1}",
          content_type: content_type,
          identify: false
        )
      rescue ArgumentError
        nil
      end

      def speech_blob(result)
        audio = result.audio
        return if audio.to_s.empty?
        content_type = SimpleInference::MediaType.detect(audio)
        return unless SimpleInference::MediaType.audio?(content_type)

        ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(audio),
          filename: "#{@invocation.public_id}-audio-output",
          content_type: content_type,
          identify: false
        )
      end

      # ---- failure classification -------------------------------------------

      # 400 and 413 ONLY. opencode's own list is wider (400|404|409|413|422)
      # and nothing in our lane set answers 404/409/422 for length — each
      # widening buys false positives against no evidence.
      OVERFLOW_STATUSES = [400, 413].freeze
      # Run first, from opencode: a throttling phrase read as "too long"
      # would compact a conversation that was merely rate limited.
      OVERFLOW_EXCLUSIONS = [
        /\A(throttling error|service unavailable):/i,
        /rate limit/i,
        /too many requests/i,
      ].freeze
      # One evidenced pattern per lane. Deliberately absent:
      # `model_context_window_exceeded` (a truncated answer, not an
      # oversized input) and the generic phrases the exclusions above fight.
      OVERFLOW_PATTERNS = [
        /prompt is too long/i,                        # anthropic, token overflow
        /request_too_large/i,                         # anthropic, byte overflow (413)
        /input token count.*exceeds the maximum/i,    # gemini
        /maximum context length is \d+ tokens/i,      # openrouter
      ].freeze

      def transient?(error) = self.class.transient_error?(error)

      # A length rejection is not a 400 everywhere: the Responses family
      # answers 200 and fails inside the stream with a routable `code`.
      def failure_reason
        return ModelInvocation::CONTEXT_OVERFLOW_KEY if context_overflow?
        return ModelInvocation::OVERLOADED_KEY if @outcome.error.overloaded?

        case @outcome.error
        when SimpleInference::HTTPError
          [401, 403, 404].include?(@outcome.error.status) ? "provider_model_unavailable" : "provider_http_error"
        else "provider_error"
        end
      end

      # Tier 1 is typed and exact, tier 2 is text and narrow. Both live
      # here because `@outcome.error` is the live gem exception at this
      # frame and reaches no column afterwards: this method or nothing.
      def context_overflow?
        case @outcome.error
        # TIER 1: the one arm with no string matching in it. Exact
        # equality on the provider's own code, which is the predicate
        # both codex and opencode ship in production.
        when SimpleInference::Protocols::OpenAIResponses::ResponseFailedError
          @outcome.error.code == "context_length_exceeded"
        # TIER 2: text, and narrow. Reached only by the three lanes that
        # deliver length as a STATUS.
        when SimpleInference::HTTPError
          http_context_overflow?(@outcome.error)
        else
          false
        end
      end

      def http_context_overflow?(error)
        return false unless OVERFLOW_STATUSES.include?(error.status)

        detail = overflow_detail(error)
        return false if OVERFLOW_EXCLUSIONS.any? { |pattern| pattern.match?(detail) }

        OVERFLOW_PATTERNS.any? { |pattern| pattern.match?(detail) }
      end

      # Structured fields only, never `raw_body`: an echoed prompt would let
      # a caller's own text make the kernel compact on demand.
      def overflow_detail(error)
        inner = provider_error_fields(error)
        [inner["message"], inner["code"], inner["type"], error.message]
          .compact.join(" ")
      end

      def provider_error_fields(error)
        body = Hash.try_convert(error.body) || {}
        Hash.try_convert(body["error"]) || {}
      end

      # WHAT THE PROVIDER ANSWERED, persisted beside the key: the status
      # and the sentence the gem already read off the structured error (a
      # bare string error rides as its message), then the code and type
      # when named — the same fields the overflow classifier reads, never
      # `raw_body`. Reading a 400 used to need a live-DB read of the stored
      # request and a paid replay.
      def failure_detail
        error = @outcome.error
        case error
        when SimpleInference::HTTPError
          inner = provider_error_fields(error)
          tags = [inner["code"], inner["type"]].compact.map(&:to_s).reject(&:empty?)
          detail = "HTTP #{error.status}: #{error.message}"
          tags.empty? ? detail : "#{detail} (#{tags.join(", ")})"
        when SimpleInference::Protocols::OpenAIResponses::ResponseFailedError
          [error.code, error.message].compact.map(&:to_s).reject(&:empty?).uniq.join(": ")
        else
          error&.message.to_s.presence
        end
      end

      # Retry-After when named, else 10 seconds per attempt spent. Capped:
      # the header is wire-controlled and an unbounded value overflowed the
      # datetime column past every rescue.
      MAX_RETRY_AFTER_SECONDS = 3600

      def cooldown_seconds
        retry_after || RETRY_COOLDOWN_STEP * @attempt.ordinal
      end

      def retry_after
        case @outcome.error
        when SimpleInference::HTTPError
          raw = (@outcome.error.headers || {})["retry-after"].to_s
          seconds = retry_after_seconds(raw)
          seconds&.clamp(..MAX_RETRY_AFTER_SECONDS)
        else
          nil
        end
      end

      # Both RFC forms, delta-seconds and HTTP-date; a past date clamps to
      # zero and junk falls back to the stepped default.
      def retry_after_seconds(raw)
        return raw.to_i if raw.match?(/\A\d+\z/)

        (Time.httpdate(raw) - Time.current).ceil.clamp(0..)
      rescue ArgumentError
        nil
      end
  end
end
