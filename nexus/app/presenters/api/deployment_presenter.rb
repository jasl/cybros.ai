module API
  module DeploymentPresenter
    class << self
      def state(value)
        {
          supported: value.supported, sources: value.sources.map(&:to_h), installed: value.installed&.to_h,
          candidate: value.candidate && candidate(value.candidate), preflight: value.preflight&.to_h,
          active_operation: value.active_operation && receipt(value.active_operation),
          last_operation: value.last_operation && receipt(value.last_operation),
        }
      end

      def candidate(value)
        value.target.to_h.merge(checked_at: value.checked_at,
          source_revision: value.source_revision, source_url: value.source_url)
      end

      def receipt(value)
        {
          id: value.id, idempotency_key: value.idempotency_key, actor_public_id: value.actor_public_id,
          target: value.target.to_h, previous: value.previous&.to_h,
          phase: value.phase, status: value.status, accepted_at: value.accepted_at,
          updated_at: value.updated_at, completed_at: value.completed_at,
          error: value.error && error(value.error), recovery: value.recovery, log_cursor: value.log_cursor,
          backup: value.backup, database_backup: value.database_backup&.to_h,
        }
      end

      def log(value)
        { entries: value.entries.map(&:to_h), next_cursor: value.next_cursor, operation: receipt(value.operation) }
      end

      def error(value)
        { code: value.code, message: value.message, operation_id: value.operation_id }.compact
      end
    end
  end
end
