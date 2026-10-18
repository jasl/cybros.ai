module Runs
  # running → paused on the virtual clock: graceful stops scheduling, force
  # interrupts in-flight steps as a requeue, never a failure.
  class Pause
    Command = Data.define(:run, :acting_user, :force) do
      def self.graceful(run:, acting_user:)
        new(run: run, acting_user: acting_user, force: false)
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
      unless @command.run.writable_by?(@command.acting_user)
        return Result.refused(:not_authorized)
      end

      run = @command.run
      run.with_lock do
        next Result.refused(:not_found) if run.tombstoned?
        # force may also ESCALATE an already-graceful pause; a plain pause
        # of a paused loop is a conflict, not a no-op — the caller should
        # know they are not the one who paused it.
        pausable = run.running? || (@command.force && run.paused?)
        next Result.refused(:not_pausable) unless pausable

        abort_in_flight(run) if @command.force
        if run.running?
          Transition.run(run, status: "paused",
            paused_at: Deployments::Maintenance.effective_now(Time.current))
        end
        Result.accepted
      end.tap do |result|
        ConvergeTerminalStepsJob.perform_later if result.accepted? && @command.force
      end
    end

    private

      # Ascending id, the multi-invocation locker's duty; the converger
      # reads `interrupted` back as a requeue, never a failure.
      def abort_in_flight(run)
        ids = run.tasks
          .where(status: "running", type: ::Tasks::ModelTask.sti_name)
          .where.not(selected_model_invocation_id: nil)
          .pluck(:selected_model_invocation_id).compact.sort
        ModelInvocation.where(id: ids).order(:id).lock.each do |invocation|
          invocation.terminalize(status: "canceled", reason_key: "interrupted")
        end
      end
  end
end
