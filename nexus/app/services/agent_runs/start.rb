module AgentRuns
  # pending → running. Creation authors the graph; starting it spends
  # money — two intents, deliberately (a client assembles the seed batch,
  # inspects the trace, then pulls the trigger).
  class Start
    Command = Data.define(:agent_run, :acting_user)

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
      unless @command.agent_run.writable_by?(@command.acting_user)
        return Result.refused(:not_authorized)
      end

      agent_run = @command.agent_run
      result = agent_run.with_lock do
        if agent_run.tombstoned?
          Result.refused(:not_found)
        elsif !agent_run.pending?
          Result.refused(:not_startable)
        else
          Transition.agent_run(agent_run, status: "running", started_at: Time.current)
          Result.accepted
        end
      end
      ScheduleJob.perform_later(@command.agent_run.id) if result.accepted?
      result
    end
  end
end
