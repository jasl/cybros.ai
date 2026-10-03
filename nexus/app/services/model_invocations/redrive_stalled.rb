module ModelInvocations
  # The rediscovery scan: a lost wake delays work, never loses it. Blunt
  # because the start CAS makes a second RunJob harmless; expired and
  # terminal-parent rows belong to the other two owners.
  class RedriveStalled
    BUDGET = 500
    # Long enough to clear queue backlog (a duplicate pays a full compile
    # before losing the CAS) and short enough to leave a window on the
    # shortest lane; redrive_stalled_test.rb pins it below the shortest shipped deadline.
    GRACE = 1.minute

    def self.call(...) = new(...).call

    def initialize(budget: BUDGET, after_id: 0)
      @budget = budget
      @after_id = after_id
    end

    def call
      now = DatabaseClock.now
      attempts = frontier(now)
      redriven = attempts.select { |attempt| redrivable?(attempt) }
      Wake.after_commit_batch(attempts: redriven)

      Sweeps::Pass.new(
        counts: { redriven: redriven.length, scanned: attempts.length },
        cursor: attempts.last&.id || @after_id,
        more: attempts.length == @budget
      )
    end

    private

      # `created_at` is the age test: the wake follows admission immediately,
      # so the row's birth is when it should have been woken.
      def frontier(now)
        ModelInvocationAttempt
          .where(status: "prepared")
          .where(created_at: ..(now - GRACE))
          .where(deadline_at: now..)
          .where(id: (@after_id + 1)..)
          .order(:id)
          .limit(@budget)
          .select(:id, :public_id, :model_invocation_id, :status)
          .preload(:model_invocation)
          .to_a
      end

      # No locks and no writes: this decides nothing and changes nothing. It
      # re-asks a question, and every rule about who may start the work still
      # lives in the CAS that answers it.
      def redrivable?(attempt)
        return false unless attempt.prepared?

        invocation = attempt.model_invocation
        invocation.running?
      end
  end
end
