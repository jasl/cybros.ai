module DeviceAuthorizations
  # Cancel and Consume serialize on the Request row, so a 200 is
  # safe-to-kill and a consumed loser must adopt the token response.
  class MachineCancel
    Result = Data.define(:outcome) do
      class << self
        def canceled
          new(outcome: :canceled)
        end

        def consumed
          new(outcome: :consumed)
        end

        private :new
      end
    end

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(authorization:)
      @authorization = authorization
    end

    def call
      ApplicationRecord.transaction do
        # A guarded update cannot distinguish a pre-credential terminal state
        # from consumed. This row lock is the shared Cancel-vs-Consume winner
        # and touches no other aggregate.
        authorization = DeviceAuthorization.lock.find(@authorization.id)
        case authorization.status
        when "pending", "connected"
          authorization.record_cancellation
          Result.canceled
        when "canceled", "expired", "invalidated"
          Result.canceled
        when "consumed"
          Result.consumed
        else
          raise ArgumentError,
            "unsupported device authorization status: #{authorization.status.inspect}"
        end
      end
    end
  end
end
