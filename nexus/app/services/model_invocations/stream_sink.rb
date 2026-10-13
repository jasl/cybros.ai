module ModelInvocations
  # Every hook a host may call while a stream is in flight, all no-ops so a
  # sink implements only what it hears.
  class StreamSink
    # THE ONE SINK CONSTRUCTOR, AND BOTH HOSTS CALL IT (one
    # implementation): which host claimed an attempt is an operational fact,
    # and a person watching must not be able to tell — so the reactor host
    # and the queue job build the same sink for the same attempt. While the
    # job host built none, a loop-backed round the queue worker claimed
    # narrated nothing at all, and whether anybody saw the model write was a
    # coin toss between two hosts nobody chose between.
    #
    # Each narrating plane gets its own kind: a hosted plane's — a loop step
    # on whichever host its loop has, a direct reply — publishes and writes
    # nothing, resolving the host itself, and BOTH hosts build it. A
    # InferenceRequest's narration is durable instead, appended under the inference_request
    # lock, and it stays the reactor's alone: the queue pair is that plane's
    # honestly degraded fallback, which `inference_request_hosts_test` pins as the
    # absence of deltas. Without a narrating owner, no sink is built.
    #
    # The host is an argument because that ONE difference is data at this
    # site rather than a second chooser somewhere else.
    def self.for(attempt:, host:)
      invocation = attempt.model_invocation
      return durable_sink(attempt, host) if invocation.inference_request_id.present?
      return ConversationEvents::StreamSink.new(attempt: attempt) if
        invocation.agent_run_id.present? || invocation.conversation_id.present?

      nil
    end

    def self.durable_sink(attempt, host)
      return nil unless host == ModelRunner::Host::HOST

      InferenceRequestEvents::StreamSink.new(attempt: attempt)
    end
    private_class_method :durable_sink

    # The attempt is dialled: after the start claim, before the first
    # byte (the kernel's `round_started` frame rides here).
    def on_attempt_started(model_invocation, attempt); end
    def on_event(model_invocation, event); end
    def on_retry(model_invocation); end
    def on_stream_settled(model_invocation); end
    # The stream ended in a declined answer, which the apply discards: what
    # streamed is withdrawn, never settled.
    def on_refused(model_invocation); end
    # The attempt failed and nothing retries it (a budget spent mid-stream,
    # a terminal error): the row holds none of it, so what streamed is
    # withdrawn, never settled.
    def on_failed(model_invocation); end
    def on_stream_canceled(model_invocation); end
  end
end
