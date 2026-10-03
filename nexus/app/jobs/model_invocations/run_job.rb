module ModelInvocations
  # The Solid Queue execution host: `ExecuteAttempt` under this host's name,
  # with the sink `StreamSink.for` builds for this one. On the HOSTED plane
  # that is the same sink the reactor builds, on the same feed — which host
  # claimed a reply is not something a person watching should be able to
  # tell. The queue pair stays the DEGRADED PAIR in what it costs (a worker
  # thread per stream rather than a fiber) and on the OneShot plane, whose
  # durable narration is the reactor's alone.
  class RunJob < ApplicationJob
    HOST = "solid_queue".freeze

    def perform(attempt_public_id)
      attempt = ModelInvocationAttempt.find_by(public_id: attempt_public_id)
      return if attempt.nil?

      ExecuteAttempt.call(
        attempt: attempt, host: HOST,
        stream_sink: StreamSink.for(attempt: attempt, host: HOST)
      )
    end
  end
end
