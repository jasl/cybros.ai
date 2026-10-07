module Schedules
  # Management and dispatch share the parent arbiter. Removing an already
  # accepted child input remains an ordinary input mutation under its own host.
  class Manage
    Outcome = Conversations::Outcome

    def self.revise(job, ...) = new(job).revise(...)
    def self.transition(job, ...) = new(job).transition(...)

    def initialize(job)
      @job = job
      @conversation = job.conversation
    end

    def revise(attributes, by:, expected_lock_version:)
      @conversation.with_lock do
        @job.reload
        next Outcome.refused(:not_authorized) unless @conversation.writable_by?(by)
        next Outcome.refused(:stale_object) unless @job.lock_version == expected_lock_version
        next Outcome.refused(:schedule_finished) if @job.canceled? || @job.completed?

        @job.assign_attributes(attributes)
        if @job.rule_changed? && @job.valid?
          next Outcome.invalid(@job) unless @job.reset_clock(DatabaseClock.now)
          @job.next_run_at = nil if @job.paused?
        end
        @job.save ? Outcome.accepted(@job) : Outcome.invalid(@job)
      end
    end

    def transition(command, by:)
      @conversation.with_lock do
        @job.reload
        next Outcome.refused(:not_authorized) unless @conversation.writable_by?(by)

        case command
        when :pause
          next Outcome.accepted(@job) if @job.paused? || @job.canceled? || @job.completed?

          @job.update!(status: "paused", next_run_at: nil)
        when :resume
          next Outcome.accepted(@job) if @job.active?
          next Outcome.refused(:schedule_finished) unless @job.paused?
          next Outcome.invalid(@job) unless @job.reset_clock(DatabaseClock.now)

          @job.update!(status: "active", last_error_code: nil)
        when :cancel
          next Outcome.accepted(@job) if @job.canceled?

          cancel_waiting_execution
          @job.update!(status: "canceled", next_run_at: nil)
        else
          raise ArgumentError, "unknown scheduled job command: #{command}"
        end
        Outcome.accepted(@job)
      end
    end

    private

      def cancel_waiting_execution
        child = @job.last_execution_conversation
        return unless child

        child.with_lock do
          input = child.conversation_inputs.find_by(public_id: child.scheduled_input_public_id)
          Conversations::Inputs::Destroy.remove(input) if input
        end
      end
  end
end
