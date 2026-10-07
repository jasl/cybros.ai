module InferenceRequests
  # Appends the terminal replay event; the invocation public id is the
  # append boundary's idempotency key. The converger holds the lock and
  # verified terminality.
  class RecordTerminalEvent
    def self.call(...) = new(...).call

    # `model_change` is the switch this terminal led to, if any.
    def initialize(invocation:, model_change: nil)
      @invocation = invocation
      @inference_request = invocation.inference_request
      @model_change = model_change
    end

    def call
      return false if @inference_request.nil?

      InferenceRequestEvents::Append.call(
        inference_request: @inference_request,
        idempotency_key: @invocation.public_id,
        items: ModelInvocations::TerminalEventItems.call(invocation: @invocation, model_change: @model_change)
      )
      true
    end
  end
end
