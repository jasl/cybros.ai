module ModelInvocations
  # Admission holds nothing — the owner accepted bounded overspend over
  # reservations — so this creates only the Attempt: ordinal, deadline,
  # admission shape and principal attribution.
  class AdmitUsage
    Result = Data.define(:attempt) do
      def self.admitted(attempt) = new(attempt: attempt)

      def admitted? = true
    end

    def self.call(...) = new(...).call

    # `consumer` and `payer` are the principals the caller already resolved
    # AND locked. `quote` is the accepted cost shape. `ordinal` is the
    # prospective next Attempt ordinal allocated under the Invocation lock.
    def initialize(invocation:, quote:, consumer:, payer:, ordinal:)
      @invocation = invocation
      @quote = quote
      @consumer = consumer
      @payer = payer
      @ordinal = ordinal
    end

    def call
      Result.admitted(create_attempt(admitted_at: DatabaseClock.now))
    end

    private

      # Admission is the deadline's first writer; provider start only freezes
      # it, or an unclaimed attempt would restart its clock when finally claimed.
      def create_attempt(admitted_at:)
        @invocation.attempts.create!(
          account: @invocation.account,
          ordinal: @ordinal,
          deadline_at: admitted_at + deadline_seconds,
          admission_shape: @quote.shape,
          consumer_public_id: @consumer.public_id,
          payer_public_id: @payer.public_id
        )
      end

      def deadline_seconds = @invocation.admission_deadline_seconds
  end
end
