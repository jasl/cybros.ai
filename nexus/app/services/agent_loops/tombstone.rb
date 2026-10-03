module AgentLoops
  # Marks the loop for physical reap and starts the retention clock. Live
  # work refuses rather than being canceled on the caller's behalf: the
  # loop has its own stop verb.
  class Tombstone
    Result = Data.define(:outcome, :agent_loop) do
      def accepted? = outcome == :accepted
    end

    def self.call(...) = new(...).call

    def initialize(agent_loop:)
      @agent_loop = agent_loop
    end

    def call
      # The locked reload is the uncached read: a run that settled on another
      # connection is not conservatively refused from a pre-lock cached copy.
      @agent_loop.with_lock do
        next Result.new(outcome: :already_tombstoned, agent_loop: @agent_loop) if @agent_loop.tombstoned?
        next Result.new(outcome: :agent_loop_busy, agent_loop: @agent_loop) unless @agent_loop.terminal?

        @agent_loop.update!(tombstoned_at: Time.current)
        Result.new(outcome: :accepted, agent_loop: @agent_loop)
      end
    end
  end
end
