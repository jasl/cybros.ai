module Runs
  # Marks the loop for physical reap and starts the retention clock. Live
  # work refuses rather than being canceled on the caller's behalf: the
  # loop has its own stop verb.
  class Tombstone
    Result = Data.define(:outcome, :run) do
      def accepted? = outcome == :accepted
    end

    def self.call(...) = new(...).call

    def initialize(run:)
      @run = run
    end

    def call
      # The locked reload is the uncached read: a run that settled on another
      # connection is not conservatively refused from a pre-lock cached copy.
      @run.with_lock do
        next Result.new(outcome: :already_tombstoned, run: @run) if @run.tombstoned?
        next Result.new(outcome: :run_busy, run: @run) unless @run.terminal?

        @run.update!(tombstoned_at: Time.current)
        Result.new(outcome: :accepted, run: @run)
      end
    end
  end
end
