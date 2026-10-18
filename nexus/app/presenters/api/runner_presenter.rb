module API
  # Management retains revoked and credential-less machines. Execution eligibility
  # is a separate fact for this Human; it grants no authority to an answering Agent.
  class RunnerPresenter
    class << self
      def basic(runner, principal:, readiness:, live_server_ids:)
        {
          public_id: runner.public_id,
          kind: runner.executor_kind,
          display_name: runner.display_name,
          status: runner.status,
          manager_public_id: runner.manager.public_id,
          assignment_scope: runner.assignment_scope,
          assignment_agent_public_id: runner.assignment_agent&.public_id,
          credential_readiness: readiness.fetch(runner.id),
          eligible_for_current_user: runner.eligible_for?(principal, readiness: readiness),
          presence: Nexus::Presence.of(runner, live_server_ids: live_server_ids),
          last_seen_at: runner.last_seen_at,
          connected_at: runner.connected_at,
          registered_at: runner.created_at,
        }
      end

      def full(runner, **context)
        basic(runner, **context).merge(
          served_tools: runner.served_tools,
          served_documents: runner.served_documents,
          environment: runner.environment,
        )
      end
    end
  end
end
