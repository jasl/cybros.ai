module ModelInvocations
  # The one command every pre-IO ending shares. Proven-unstarted is the
  # whole precondition: an attempt that reached the provider may have been
  # billed and is closed by settlement with a receipt, never relabelled here.
  class CancelUnstarted
    TERMINALIZED = :terminalized
    # Already terminal. Arriving second is ordinary rather than exceptional —
    # this reports what it found and writes nothing.
    REPLAYED = :replayed
    # The Attempt reached the provider. Refusing is the point.
    STARTED = :attempt_started

    # The caller names the class — sweep `timed_out`, cut `canceled`, else
    # `failed` — so an operator can tell what ended each dead ordinal.
    TERMINAL_STATUSES = %w[failed canceled timed_out].freeze

    Result = Data.define(:outcome, :attempt) do
      def terminalized? = outcome == TERMINALIZED
      def replayed? = outcome == REPLAYED
    end

    def self.call(...) = new(...).call

    def initialize(attempt:, terminal_status:, at: nil)
      @attempt = attempt
      @terminal_status = terminal_status.to_s
      @at = at
    end

    def call
      unless TERMINAL_STATUSES.include?(@terminal_status)
        raise ArgumentError, "unknown pre-start terminal status: #{@terminal_status}"
      end

      @attempt.reload
      return Result.new(outcome: STARTED, attempt: @attempt) if @attempt.started?
      return Result.new(outcome: REPLAYED, attempt: @attempt) unless @attempt.prepared?

      @attempt.update!(
        status: @terminal_status, settlement_state: "not_applicable",
        terminal_at: @at || DatabaseClock.now
      )
      Result.new(outcome: TERMINALIZED, attempt: @attempt)
    end
  end
end
