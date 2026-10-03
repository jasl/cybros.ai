module OneShotEvents
  # The OneShot's durable streaming narration: deltas coalesced and
  # appended under the one_shot lock, only while the invocation is running.
  # The rollback marker's gate is wider: after the requeue, before a newer ordinal.
  class StreamSink < ModelInvocations::StreamSink
    include ModelInvocations::DeltaCoalescing

    TEXT_DELTA_KEY = [:text].freeze

    def initialize(attempt:, **coalescing)
      @attempt = attempt
      @model_invocation = attempt.model_invocation
      @one_shot = @model_invocation.one_shot
      @emitted_public_delta = false
      initialize_delta_coalescing(**coalescing)
    end

    def on_event(model_invocation, event)
      return unless model_invocation.id == @model_invocation.id

      case event
      when SimpleInference::Responses::Events::TextDelta
        coalesce_delta(TEXT_DELTA_KEY, event.delta.to_s)
      when SimpleInference::Responses::Events::ReasoningDelta
        coalesce_delta([:reasoning, event.kind], event.delta.to_s)
      else
        # Raw, Completed, and the tool-call family pass through: raw frames
        # and terminals are not narration, and tool narration returns with
        # the agent loop.
        nil
      end
    end

    def on_stream_settled(model_invocation)
      return unless model_invocation.id == @model_invocation.id

      raise_pending_flush_error
      flush_pending_delta
    end

    def on_stream_canceled(model_invocation)
      return unless model_invocation.id == @model_invocation.id

      discard_pending_delta
    end

    # A transient retry throws this attempt's streamed output away: discard
    # the pending tail and — only when something PUBLIC already streamed —
    # append the rollback marker so a replaying client knows to reset.
    def on_retry(model_invocation)
      return unless model_invocation.id == @model_invocation.id

      withdraw("retry")
    end

    # A declined answer is discarded from storage, so its streamed partial is
    # rolled back the same way. The invocation still runs here — the apply
    # has not committed — so the marker's gate passes.
    def on_refused(model_invocation)
      return unless model_invocation.id == @model_invocation.id

      withdraw("refused")
    end

    # A failed attempt nothing retries holds none of what it streamed: the
    # partial is withdrawn as a declined one is, never flushed.
    def on_failed(model_invocation)
      return unless model_invocation.id == @model_invocation.id

      withdraw("failed")
    end

    private

      def withdraw(reason)
        abandon_pending_delta
        return unless @emitted_public_delta

        append_rollback(reason)
        @emitted_public_delta = false
      end

      def append_coalesced_delta(key, text)
        item_type, payload_extra =
          if key == TEXT_DELTA_KEY
            ["text_delta", {}]
          else
            ["reasoning_delta", { "kind" => key.last.to_s }]
          end
        items = Nexus::TextDeltaChunking.chunk(text).map do |chunk|
          { type: item_type, payload: { "text" => chunk }.merge(payload_extra) }
        end
        return if items.empty?

        append_guarded(items) { |invocation| invocation.running? }
      end

      def append_rollback(reason)
        append_guarded(
          [{ type: "rollback",
             payload: { "one_shot_public_id" => @one_shot.public_id, "reason" => reason } }]
        ) do |invocation|
          !invocation.terminal? && latest_ordinal?
        end
      end

      # Aggregate lock first, invocation lock under it, then the gate: the
      # second lock makes the gate atomic with authority cuts. A refusal is
      # never silent — it drops received, billed narration.
      def append_guarded(items)
        appended = false
        status = nil
        ApplicationRecord.transaction do
          @one_shot.lock!
          # The invocation second, under its one_shot: the append and the
          # terminal converger race on this row, and `status` is read after
          # the lock so a cut mid-stream is seen, not raced.
          invocation = @model_invocation.lock!
          status = invocation.status
          next unless yield(invocation)

          Append.call(one_shot: @one_shot, items: items)
          appended = true
        end
        appended ? @emitted_public_delta = true : report_dropped(items, status)
        appended
      end

      # The line names what a short reply lost, and where: the invocation,
      # the ordinal that streamed it, the status the gate read, the bytes.
      def report_dropped(items, status)
        bytes = items.sum { |item| item[:payload]["text"].to_s.bytesize }
        Rails.logger.warn(
          "event=one_shot_narration_dropped invocation=#{@model_invocation.public_id} " \
          "ordinal=#{@attempt.ordinal} status=#{status} " \
          "items=#{items.map { |item| item[:type] }.uniq.join(",")} bytes=#{bytes}"
        )
      end

      # The ordinal this sink narrates is FROZEN at construction: once a
      # NEWER ordinal has started, the stream belongs to it and a late
      # rollback from this one would race its deltas.
      def latest_ordinal?
        !@model_invocation.attempts
          .where(ordinal: (@attempt.ordinal + 1)..)
          .where.not(provider_started_at: nil)
          .exists?
      end
  end
end
