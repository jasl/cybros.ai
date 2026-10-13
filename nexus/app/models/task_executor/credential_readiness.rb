module TaskExecutor::CredentialReadiness
  extend ActiveSupport::Concern

  class_methods do
    # Page-sized projection of transport credential readiness without loading
    # unbounded associations or issuing one EXISTS pair per row.
    def credential_readiness_for(executors, now: Time.current)
      executor_ids = executors.map(&:id)
      return {} if executor_ids.empty?

      ready_ids = access_ready_ids(executor_ids, now:).to_set
      remaining_ids = executor_ids - ready_ids.to_a
      if remaining_ids.any?
        ready_ids.merge(refresh_ready_ids(remaining_ids, now:))
      end

      executor_ids.index_with do |executor_id|
        ready_ids.include?(executor_id) ? :ready : :no_credential
      end
    end

    private

      def access_ready_ids(executor_ids, now:)
        AccessToken
          .joins(:task_executor)
          .where(task_executor_id: executor_ids, revoked_at: nil)
          .where.not(task_executors: { status: :revoked })
          .where("access_tokens.credential_epoch = task_executors.credential_epoch")
          .merge(AccessToken.where(expires_at: nil).or(AccessToken.where.not(expires_at: ..now)))
          .where(<<~SQL.squish)
            access_tokens.refresh_token_family_id IS NULL OR EXISTS (
              SELECT 1
              FROM refresh_token_families
              WHERE refresh_token_families.id = access_tokens.refresh_token_family_id
                AND refresh_token_families.revoked_at IS NULL
            )
          SQL
          .distinct
          .pluck("access_tokens.task_executor_id")
      end

      def refresh_ready_ids(executor_ids, now:)
        RefreshToken
          .joins(refresh_token_family: :task_executor)
          .where(consumed_at: nil, superseded_by_id: nil, revoked_at: nil)
          .where(
            refresh_token_families: {
              task_executor_id: executor_ids,
              revoked_at: nil,
            }
          )
          .where.not(task_executors: { status: :revoked })
          .where("refresh_token_families.credential_epoch = task_executors.credential_epoch")
          .where.not(refresh_token_families: { last_used_at: ..(now - RefreshTokenFamily::INACTIVITY_WINDOW) })
          .distinct
          .pluck("refresh_token_families.task_executor_id")
      end
  end
end
