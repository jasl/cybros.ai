module Schedules
  # Management and dispatch share the parent arbiter. Removing an already
  # accepted child input remains an ordinary input mutation under its own host.
  class Manage
    Outcome = Conversations::Outcome

    def self.revise(job, ...) = new(job).revise(...)
    def self.transition(job, ...) = new(job).transition(...)
    def self.run_now(job, ...) = new(job).run_now(...)

    def initialize(job)
      @job = job
      @conversation = job.conversation
    end

    def revise(attributes, by:, expected_lock_version:)
      synchronize { revise_locked(attributes, by: by, expected_lock_version: expected_lock_version) }
    end

    def revise_locked(attributes, by:, expected_lock_version:)
      return Outcome.refused(:not_authorized) unless @conversation.writable_by?(by)
      return Outcome.refused(:stale_object) unless @job.lock_version == expected_lock_version
      return Outcome.refused(:schedule_finished) if @job.canceled? || @job.completed?

      @job.assign_attributes(attributes)
      if @job.rule_changed? && @job.valid?
        return Outcome.invalid(@job) unless @job.reset_clock(DatabaseClock.now)
        @job.next_run_at = nil if @job.paused?
      end
      @job.save ? Outcome.accepted(@job) : Outcome.invalid(@job)
    end

    def transition(command, by:)
      synchronize(command: command) { transition_locked(command, by: by) }
    end

    def transition_locked(command, by:)
      return Outcome.refused(:not_authorized) unless @conversation.writable_by?(by)

      case command
      when :pause
        return Outcome.accepted(@job) if @job.paused? || @job.canceled? || @job.completed?

        @job.update!(status: "paused", next_run_at: nil)
      when :resume
        return Outcome.accepted(@job) if @job.active?
        return Outcome.refused(:schedule_finished) unless @job.paused?
        return Outcome.invalid(@job) unless @job.reset_clock(DatabaseClock.now)

        @job.update!(status: "active", last_error_code: nil)
      when :cancel
        return Outcome.accepted(@job) if @job.canceled?

        @job.update!(status: "canceled", next_run_at: nil)
      else
        raise ArgumentError, "unknown scheduled job command: #{command}"
      end
      Outcome.accepted(@job)
    end

    # Dispatch uses the parent arbiter. Cancel also owns the pending child's
    # input, so acquire that host before a kernel caller locks its source Run.
    # Delete narration comes last, after a coupled tool result has been written.
    def synchronize(command: nil)
      @conversation.with_lock do
        @job.reload
        child = @job.last_execution_conversation if command == :cancel && !@job.canceled?
        if child
          child.with_lock do
            result = yield
            cancel_waiting_execution(child) if @job.canceled?
            result
          end
        else
          yield
        end
      end
    end

    # One execution now, outside the clock: Dispatch's ordinary child birth
    # under the job's saved intent, refused by the same words every other
    # schedule command uses. Dispatch holds the parent arbiter itself.
    def run_now(by:)
      result = Dispatch.call(id: @job.id, by: by)
      result == :dispatched ? Outcome.accepted(@job.reload) : Outcome.refused(result)
    end

    private

      def cancel_waiting_execution(child)
        input = child.inputs.find_by(public_id: child.scheduled_input_public_id)
        Conversations::Inputs::Destroy.remove(input) if input
      end
  end
end
