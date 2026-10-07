module AgentRuns
  # running → paused on the virtual clock: graceful stops scheduling, force
  # interrupts in-flight steps as a requeue, never a failure.
  class Pause
    Command = Data.define(:agent_run, :acting_user, :force) do
      def self.graceful(agent_run:, acting_user:)
        new(agent_run: agent_run, acting_user: acting_user, force: false)
      end
    end

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
      agent_run.with_lock do
        next Result.refused(:not_found) if agent_run.tombstoned?
        # force may also ESCALATE an already-graceful pause; a plain pause
        # of a paused loop is a conflict, not a no-op — the caller should
        # know they are not the one who paused it.
        pausable = agent_run.running? || (@command.force && agent_run.paused?)
        next Result.refused(:not_pausable) unless pausable

        abort_in_flight(agent_run) if @command.force
        if agent_run.running?
          Transition.agent_run(agent_run, status: "paused", paused_at: Time.current)
        end
        Result.accepted
      end.tap do |result|
        ConvergeTerminalStepsJob.perform_later if result.accepted? && @command.force
      end
    end

    private

      # Ascending id, the multi-invocation locker's duty; the converger
      # reads `interrupted` back as a requeue, never a failure.
      def abort_in_flight(agent_run)
        ids = agent_run.agent_run_tasks
          .where(status: "running", type: AgentRunTasks::ModelTask.sti_name)
          .where.not(selected_model_invocation_id: nil)
          .pluck(:selected_model_invocation_id).compact.sort
        ModelInvocation.where(id: ids).order(:id).lock.each do |invocation|
          invocation.terminalize(status: "canceled", reason_key: "interrupted")
        end
      end
  end
end
