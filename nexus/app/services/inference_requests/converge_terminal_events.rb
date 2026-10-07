module InferenceRequests
  # One recorder for every terminal path, outside the terminal transaction:
  # a refused event payload must never roll back a terminal flip. The
  # marker, not the event, leaves the frontier, so a refused row is not rescanned forever.
  # The record is also where a DECLINED or OVERLOADED call's run is decided — the switch
  # to the creator's declared fallback (`Fallback`) or the stand — once,
  # with the marker, so the run reads `running` until then.
  class ConvergeTerminalEvents
    BUDGET = 500

    class << self
      def call(...) = new(...).call

      # A STOP IN THE WINDOW (`InferenceRequests::Cancel`): a declined or overloaded
      # latest call no converger has recorded yet settles on the spot, with
      # no switch — a stop is never lost to a fallback nobody asked for, and
      # the marker keeps the converger from deciding it again.
      def settle_now(inference_request) = new.settle_switchable(inference_request)
    end

    def initialize(budget: BUDGET, invocation_id: nil)
      @budget = budget
      @invocation_id = invocation_id
    end

    def call
      ids = @invocation_id ? [@invocation_id] : frontier
      recorded = ids.count { |id| isolated(id) }

      Sweeps::Pass.new(counts: { recorded: recorded, scanned: ids.length },
        more: @invocation_id.nil? && ids.length == @budget)
    end

    # The aggregate first, then its latest call, as every record takes them.
    def settle_switchable(inference_request)
      ApplicationRecord.transaction do
        inference_request.lock!
        # Uncached after the lock: a terminal that committed elsewhere must
        # not be read from a pre-lock cached answer.
        invocation = ApplicationRecord.uncached { inference_request.reload_model_invocation }
        next false if invocation.nil?

        invocation.lock!
        next false unless invocation.undecided?

        settle(invocation)
      end
    end

    private

      # The partial index's own predicate, verbatim: the frontier needs no
      # cursor because stamping the marker removes the row.
      def frontier
        ModelInvocation
          .where(status: ModelInvocation::TERMINAL_STATUSES)
          .where(terminal_event_recorded_at: nil)
          .where.not(inference_request_id: nil)
          .order(:id)
          .limit(@budget)
          .pluck(:id)
      end

      # The inference_request lock first: every event INSERT takes KEY SHARE on the
      # aggregate through its FK, and Drain walks the pair in that order.
      # Terminal before any lock, too: a call's terminal facts are
      # write-once, so what the switch's decision reads off them here cannot
      # move under the locks below; a call that terminalizes later records
      # on its own wake.
      def record(id)
        invocation = ModelInvocation.find_by(id: id)
        return false unless invocation&.terminal?

        inference_request = invocation.inference_request
        return false if inference_request.nil?

        fallback = Fallback.new(inference_request: inference_request, invocation: invocation)
        ApplicationRecord.transaction do
          # Create's authority locks, ahead of the aggregate — taken only
          # for a declined call that may switch.
          fallback.lock_authority
          inference_request.lock!
          # The invocation second, under its inference_request: the once-only terminal
          # stamp races the stream sink's own append on this row, and both
          # must read the same `terminal_event_recorded_at`.
          invocation.lock!
          next false unless invocation.terminal?
          next false unless invocation.terminal_event_recorded_at.nil?

          settle(invocation, model_change: fallback.call)
        end
      end

      # The terminal event and the marker, in the caller's transaction.
      def settle(invocation, model_change: nil)
        appended = append_best_effort(invocation, model_change)
        invocation.update!(terminal_event_recorded_at: DatabaseClock.now)
        appended
      end

      # A refused event costs the event, never the marker or the pass — and
      # never a transaction: the append runs in its own SAVEPOINT so a
      # refused payload cannot poison the marker write beside it.
      def append_best_effort(invocation, model_change)
        ApplicationRecord.transaction(requires_new: true) do
          RecordTerminalEvent.call(invocation: invocation, model_change: model_change)
        end
      rescue ActiveRecord::RecordInvalid, ActiveModel::RangeError => error
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "inference_request_terminal_event_unwritable", invocation: invocation.public_id })
        false
      end

      # One row's failure is one row's — the poison-row lesson, inherited
      # from the post-cut converger verbatim.
      def isolated(id)
        record(id)
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "inference_request_terminal_event_converge_failed", invocation_id: id })
        false
      end
  end
end
