module AgentRuns
  # Marks the loop for physical reap and starts the retention clock. Live
  # work refuses rather than being canceled on the caller's behalf: the
  # loop has its own stop verb.
  class Tombstone
    Result = Data.define(:outcome, :agent_run) do
      def accepted? = outcome == :accepted
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      # The locked reload is the uncached read: a run that settled on another
      # connection is not conservatively refused from a pre-lock cached copy.
      @agent_run.with_lock do
        next Result.new(outcome: :already_tombstoned, agent_run: @agent_run) if @agent_run.tombstoned?
        next Result.new(outcome: :run_busy, agent_run: @agent_run) unless @agent_run.terminal?

        @agent_run.update!(tombstoned_at: Time.current)
        Result.new(outcome: :accepted, agent_run: @agent_run)
      end
    end
  end
end
