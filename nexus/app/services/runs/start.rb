module Runs
  # pending → running. Creation authors the graph; starting it spends
  # money — two intents, deliberately (a client assembles the seed batch,
  # inspects the trace, then pulls the trigger).
  class Start
    Command = Data.define(:run, :acting_user)

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
      unless @command.run.writable_by?(@command.acting_user)
        return Result.refused(:not_authorized)
      end

      run = @command.run
      result = run.with_lock do
        if run.tombstoned?
          Result.refused(:not_found)
        elsif !run.pending?
          Result.refused(:not_startable)
        else
          Transition.run(run, status: "running", started_at: Time.current)
          Result.accepted
        end
      end
      ScheduleJob.perform_later(@command.run.id) if result.accepted?
      result
    end
  end
end
