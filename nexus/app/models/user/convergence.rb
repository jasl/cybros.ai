module User::Convergence
  extend ActiveSupport::Concern

  BATCH_SIZE = 500

  STEWARD_SHUTDOWN_PENDING_SQL = <<~SQL.squish.freeze
    EXISTS (
      SELECT 1
      FROM users AS stewards
      WHERE stewards.id = users.steward_id
        AND stewards.managed_resource_shutdown_generation <>
          users.applied_steward_shutdown_generation
    )
  SQL

  class_methods do
    # Turns each affected Agent Profile into a stopped resource; a Profile with no address
    # still converges. The window comes first through the partial
    # `index_users_on_agent_profile_window`; the mismatch has no index.
    def converge(batch_size: BATCH_SIZE, after_id: 0)
      window = where(kind: :agent).where(id: (after_id + 1)..)
        .order(:id).limit(batch_size).pluck(:id)

      converged = members
        .includes(:steward)
        .where(id: window)
        .where(STEWARD_SHUTDOWN_PENDING_SQL)
        .count do |profile|
          steward = profile.steward
          profile.converge_steward_shutdown(
            expected_steward_id: steward&.id,
            expected_generation: steward&.managed_resource_shutdown_generation,
            expected_applied_generation: profile.applied_steward_shutdown_generation
          ) == :converged
        end

      Rails.logger.info "event=users_converged steward_shutdowns=#{converged}"
      Sweeps::Pass.new(
        counts: { converged: converged, scanned: window.length },
        cursor: window.empty? ? after_id : window.last,
        more: batch_size.positive? && window.length == batch_size
      )
    end
  end

  # Locks only the Profile: holding the Human row while mutating a downstream
  # resource would invert the two-phase boundary. A later removal only leaves
  # the mismatch for the next pass.
  def converge_steward_shutdown(
    expected_steward_id:,
    expected_generation:,
    expected_applied_generation:
  )
    # Three expected values and one set update, and the answer names which
    # of them drifted (`:steward_changed`, `:stale`, `:already_converged`)
    # — a CAS's 0 rows changed cannot.
    with_lock do
      return :steward_changed unless steward_id == expected_steward_id

      if applied_steward_shutdown_generation != expected_applied_generation
        :stale
      elsif applied_steward_shutdown_generation == expected_generation
        :already_converged
      else
        revoke_agent_credentials if active?
        # The set update comes before the Profile acknowledges the generation;
        # ordinary User removal would win the wrong reason.
        ModelInvocation::Cancellation.call(
          scope: ModelInvocation.where(creating_user_id: id),
          reason: "steward_removed",
          steward_shutdown_generation: expected_generation
        )

        update!(
          applied_steward_shutdown_generation: expected_generation,
          **(active? ? { status: :removed, authority_generation: authority_generation + 1 } : {})
        )
        :converged
      end
    end
  end
end
