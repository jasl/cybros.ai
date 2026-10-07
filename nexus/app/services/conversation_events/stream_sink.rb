module ConversationEvents
  # THE HOSTED PLANE'S STREAMING NARRATION: a direct reply, a loop-backed
  # round and a standalone round, one vocabulary on the host's transcript
  # stream. Where the deltas go is resolved ONCE, at construction, and
  # every publish reads it. Nothing here is durable: the rows are the
  # record, and a delta is neither record nor replay.
  class StreamSink < ModelInvocations::StreamSink
    include ModelInvocations::DeltaCoalescing

    TEXT_KEY = [:text].freeze

    def initialize(attempt:, **coalescing)
      @attempt = attempt
      @model_invocation = attempt.model_invocation
      @source = Conversations::TranscriptStream::Source.for(@model_invocation)
      # The loop step the Source was resolved from, kept from that one
      # lookup: `round_started` reads its mark and its sealed bytes.
      @node = @source&.node
      @emitted_public_delta = false
      initialize_delta_coalescing(**coalescing)
    end

    # THE KERNEL'S OWN FRAME (`Conversations::ProgressStream`): the
    # attempt is dialled — the round's key, its mark, the attempt, the
    # model, the sealed request's size — on the host's `progress` feed,
    # not this transcript's. A direct reply keeps no node and narrates
    # nothing here: its `turn_status`, its deltas and its settled `turn`
    # are the whole story, and nothing consumes a frame with no key.
    def on_attempt_started(model_invocation, attempt)
      return unless mine?(model_invocation)

      Conversations::ProgressStream.round_started(@source, @node, attempt)
    end

    def on_event(model_invocation, event)
      return unless mine?(model_invocation)

      case event
      when SimpleInference::Responses::Events::TextDelta
        coalesce_delta(TEXT_KEY, event.delta.to_s)
      when SimpleInference::Responses::Events::ReasoningDelta
        coalesce_delta([:reasoning, event.kind], event.delta.to_s)
      when SimpleInference::Responses::Events::ToolCallDelta
        announce_call(event)
        publish("tool_call_arguments_delta",
          call_id: call_key(event), delta: event.delta.to_s)
      else
        # Raw frames, terminals and ToolCallDone are not narration: the
        # settled turn's own snapshot is authoritative for all three.
        nil
      end
    end

    def on_stream_settled(model_invocation)
      return unless mine?(model_invocation)

      raise_pending_flush_error
      flush_pending_delta
    end

    def on_stream_canceled(model_invocation)
      return unless mine?(model_invocation)

      discard_pending_delta
    end

    # A transient retry throws this attempt's output away, so a follower
    # is told to discard rather than splice two attempts together.
    def on_retry(model_invocation)
      return unless mine?(model_invocation)

      withdraw("retry")
    end

    # A declined answer is discarded from storage, so what streamed of it is
    # withdrawn the same way — a call announced and then discarded included.
    def on_refused(model_invocation)
      return unless mine?(model_invocation)

      withdraw("refused")
    end

    # A failed attempt nothing retries holds none of what it streamed: the
    # partial is withdrawn as a declined one is, never flushed.
    def on_failed(model_invocation)
      return unless mine?(model_invocation)

      withdraw("failed")
    end

    private

      # The pending tail is dropped, never flushed; the reset is said only
      # when something public already streamed.
      def withdraw(reason)
        abandon_pending_delta
        return unless @emitted_public_delta

        publish("stream_reset", reason: reason)
        @announced_calls = nil
        @emitted_public_delta = false
      end

      # Only this sink's invocation and a resolved source may publish here.
      def mine?(model_invocation)
        @source.present? && model_invocation.id == @model_invocation.id
      end

      def announce_call(event)
        @announced_calls ||= Set.new
        key = call_key(event)
        return if key.blank? || @announced_calls.include?(key)

        @announced_calls << key
        publish("tool_call_started", call_id: key, name: event.name)
      end

      def call_key(event) = (event.call_id || event.item_id).to_s

      def append_coalesced_delta(key, text)
        if key == TEXT_KEY
          publish("text_delta", text: text)
        else
          publish("reasoning_delta", kind: key.last.to_s, text: text)
        end
      end

      def publish(type, **payload)
        @emitted_public_delta = true
        Conversations::TranscriptStream.delta(source: @source, type: type, payload: payload)
      end
  end
end
