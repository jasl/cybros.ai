module AgentLoops
  # pending → running. Creation authors the graph; starting it spends
  # money — two intents, deliberately (a client assembles the seed batch,
  # inspects the trace, then pulls the trigger).
  class Start
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
        elsif !agent_loop.pending?
          Result.refused(:not_startable)
        else
          Transition.agent_loop(agent_loop, status: "running", started_at: Time.current)
          Result.accepted
        end
      end
      ScheduleJob.perform_later(@command.agent_loop.id) if result.accepted?
      result
    end
  end
end
