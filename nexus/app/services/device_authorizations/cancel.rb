module DeviceAuthorizations
  # Cancels a browser-held Request before the machine consumes it: nothing
  # durable exists before a winning Consume, so no member, executor or
  # credential is mutated.
  class Cancel
    Result = Data.define(:outcome) do
      class << self
        def canceled
          new(outcome: :canceled)
        end

        def stale
          new(outcome: :stale)
        end

        def not_authorized
          new(outcome: :not_authorized)
        end

        private :new
      end
    end

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(authorization:, connector:)
      @authorization = authorization
      @connector = connector
    end

    def call
      return Result.not_authorized unless @connector.active_human_member?

      @authorization.with_lock do
        if @authorization.pending? || @authorization.connected?
          if @authorization.expires_at <= Time.current
            @authorization.materialize_expiry
            Result.stale
          else
            @authorization.record_cancellation
            Result.canceled
          end
        else
          Result.stale
        end
      end
    end
  end
end
