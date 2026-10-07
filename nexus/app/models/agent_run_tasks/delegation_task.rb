module AgentRunTasks
  # Observes the original execution of a turn-owned child request. It has no
  # external holder or deadline: the child execution owns its own clocks and
  # repair. Publication stores the accepted Input identity once, so transport
  # receipt expiry cannot publish a second brief.
  class DelegationTask < AgentRunTask
    attr_readonly :provider_id, :model_ref, :reasoning_effort, :reasoning_enabled

    self.task_kind = "delegation_task"
    self.transitions = {
      nil => %w[queued skipped],
      "queued" => %w[running failed canceled skipped],
      "running" => %w[completed failed canceled],
      "completed" => [], "failed" => [], "canceled" => [], "skipped" => [],
    }.freeze

    def delegation? = true

    validates :lifetime, inclusion: { in: ["turn"] }
    validates :on_failure, inclusion: { in: ["absorb"] }
    validates :retry_budget, numericality: { equal_to: 0 }
    validates :authored_by, inclusion: { in: ["kernel"] }
    validates :addressed_role, :addressed_executor_id, :timeout_ms, :await_timeout_ms,
      absence: true
    validate :publication_is_write_once

    private

      def publication_is_write_once
        return unless delegated_input_public_id_changed? && delegated_input_public_id_was.present?

        errors.add(:delegated_input_public_id, :readonly)
      end
  end
end
