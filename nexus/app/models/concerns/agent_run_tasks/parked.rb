module AgentRunTasks
  # A task waiting on someone outside the kernel: one deadline derivation,
  # one sweep, one settle engine (AgentRuns::Parks::Settle), so the sweep's
  # SQL twin can be pinned equal to it.
  module Parked
    extend ActiveSupport::Concern

    # Approval and external awaits share the per-park hold ceiling.
    MAX_HOLD = 24.hours
    MAX_HOLD_MS = MAX_HOLD.in_milliseconds

    # The owner's chain: the model's per-call timeout, else the tool's
    # announced default frozen on the row at dispatch, else the kernel's. The
    # authored intent is never rewritten (it is attr_readonly); what moves is
    # the DERIVED deadline. An await clamps this per park.
    def effective_timeout_ms
      # A held row's clock is the approver's — the ask's 24 h — never the
      # tool's run clock, which starts at dispatch.
      return MAX_HOLD_MS if held?

      authored_timeout_ms.presence || announced_timeout_ms || self.class::DEFAULT_TIMEOUT_MS
    end

    def deadline_at
      return if await_started_at.blank?

      await_started_at + (effective_timeout_ms / 1000.0)
    end

    # Executor timers run on wall time. Project the existing pause debt
    # without changing the virtual clock that Resume shifts exactly once.
    def wall_deadline_at(now = Time.current)
      deadline = deadline_at
      deadline && deadline + (now - agent_run.effective_now(now))
    end

    # Reads the loop's VIRTUAL clock by default: while the loop is
    # paused the answer cannot flip to true — a mid-pause settle is
    # adjudicated against a deadline that stands still.
    def deadline_passed?(now = nil)
      deadline = deadline_at
      deadline.present? && deadline <= (now || agent_run.effective_now)
    end

    # The bearer proof for settling this park: an await's is minted at
    # creation, a tool's at claim (and rotates so a zombie cannot settle over the live holder).
    def settlement_claim_token = nil

    # An existing execution belongs to its claimant, independently of current
    # addressing, announcements or eligibility for new work.
    def claimed_by?(executor, token:)
      token = token.to_s
      claimed_by_executor_id == executor.id && token.present? &&
        ActiveSupport::SecurityUtils.secure_compare(claim_token.to_s, token)
    end

    # On the clock: the type the sweep, the pause shift and the row's own
    # `await_started_at` invariant all read.
    def clocked? = true
  end
end
