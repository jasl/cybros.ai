module OneShots
  # Appends the terminal replay event; the invocation public id is the
  # append boundary's idempotency key. The converger holds the lock and
  # verified terminality.
  class RecordTerminalEvent
    def self.call(...) = new(...).call

    # `model_change` is the switch this terminal led to, if any.
    def initialize(invocation:, model_change: nil)
      @invocation = invocation
      @one_shot = invocation.one_shot
      @model_change = model_change
    end

    def call
      return false if @one_shot.nil?

      OneShotEvents::Append.call(
        one_shot: @one_shot,
        idempotency_key: @invocation.public_id,
        items: ModelInvocations::TerminalEventItems.call(invocation: @invocation, model_change: @model_change)
      )
      true
    end
  end
end
