module ModelInvocations
  # The after-commit wake, best-effort by design: no outbox, so a lost enqueue delays work and
  # `RedriveStalled` rediscovers it. Every capable host is woken now; the start CAS, never a
  # timer, keeps two from running one attempt.
  module Wake
    # The reactor's wake channel: an empty-payload edge trigger — the
    # committed `running`/`prepared` rows are the queue, so the
    # notification carries no id and a burst coalesces listener-side.
    NOTIFY_CHANNEL = "model_invocations_admitted".freeze

    class << self
      # The queue host gets a job per attempt in ONE bulk enqueue
      # (`perform_all_later` already defers to after commit); the runner
      # gets one NOTIFY for the batch, through the same deferral so a
      # rolled-back claim wakes nobody.
      def after_commit_batch(attempts:)
        runner_work = attempts.any? do |attempt|
          attempt.model_invocation.workload == "text_generation"
        end
        notify_runner_after_commit if runner_work

        ActiveJob.perform_all_later(attempts.map { |attempt| RunJob.new(attempt.public_id) })
        attempts.length
      end

      # Belt over PostgreSQL's own suspender (NOTIFY already waits for
      # commit): the hook holds even if the notify rides another connection.
      def notify_runner_after_commit
        ApplicationRecord.current_transaction.after_commit do
          ApplicationRecord.with_connection do |connection|
            connection.execute("SELECT pg_notify('#{NOTIFY_CHANNEL}', '')")
          end
        end
      end
    end
  end
end
