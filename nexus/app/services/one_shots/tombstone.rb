module OneShots
  # Terminal-only: marks a finished OneShot for reclamation and never
  # cancels running work on the caller's behalf.
  class Tombstone
    Result = Data.define(:outcome, :one_shot) do
      def accepted? = outcome == :accepted
    end

    def self.call(...) = new(...).call

    def initialize(one_shot:)
      @one_shot = one_shot
    end

    def call
      # The status is derived from the invocation, so the aggregate is
      # locked first — above `model_invocations` on the ladder — and read once.
      @one_shot.with_lock do
        next Result.new(outcome: :already_tombstoned, one_shot: @one_shot) if @one_shot.tombstoned?

        # Uncached after the lock, or a terminal that committed elsewhere is
        # refused from a pre-lock cached read. The aggregate's terminality,
        # not the call's: a declined answer is not terminal until recorded.
        ApplicationRecord.uncached { @one_shot.reload_model_invocation }
        next Result.new(outcome: :not_terminal, one_shot: @one_shot) unless @one_shot.terminal?

        @one_shot.update!(tombstoned_at: Time.current)
        Result.new(outcome: :accepted, one_shot: @one_shot)
      end
    end
  end
end
