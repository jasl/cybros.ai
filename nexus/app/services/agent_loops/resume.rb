module AgentLoops
  # paused → running, and the scheduler picks up everything that settled
  # while the loop stood still (results kept applying — pause only stopped
  # scheduling).
  class Resume
    Command = Data.define(:agent_loop, :acting_user)

    Result = Data.define(:outcome) do
      class << self
        def accepted = new(outcome: :accepted)
        def refused(code) = new(outcome: code)
      end

      def accepted? = outcome == :accepted
    end

    class << self
      def call(command)
        new(command).call
      end
    end

    def initialize(command)
      @command = command
    end

    def call
      unless @command.agent_loop.writable_by?(@command.acting_user)
        return Result.refused(:not_authorized)
      end

      agent_loop = @command.agent_loop
      result = agent_loop.with_lock do
        if agent_loop.tombstoned?
          Result.refused(:not_found)
        elsif !agent_loop.paused?
          Result.refused(:not_paused)
        else
          # The debt repayment: the pause's wall-time shifts out of
          # every parked clock in this same locked transaction, so the
          # loop re-exposes exactly the deadlines it froze.
          agent_loop.unfreeze
          Transition.agent_loop(agent_loop, status: "running", paused_at: nil)
          Result.accepted
        end
      end
      ScheduleJob.perform_later(@command.agent_loop.id) if result.accepted?
      result
    end
  end
end
