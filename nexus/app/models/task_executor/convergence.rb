module TaskExecutor::Convergence
  extend ActiveSupport::Concern

  BATCH_SIZE = 500

  # The parks an addressed row rests in unclaimed: a `dispatched` tool
  # row, an `awaiting_input` ask, a tool row resting for its approver —
  # the addressed-frontier index's shape. The one declaration of the set,
  # also read by the recovering park sweep and shutdown gate.
  UNCLAIMED_PARKED_STATUSES = %w[dispatched awaiting_input needs_approval].freeze

  ShutdownBatch = Data.define(:converged, :scanned, :cursor)
  ReapBatch = Data.define(:reaped, :scanned, :cursor)
  DURABLE_DEPENDENCY_JOINS_SQL = <<~SQL.squish.freeze
    LEFT JOIN LATERAL (
      SELECT 1 AS matched
      FROM access_tokens
      WHERE access_tokens.task_executor_id = task_executors.id
      LIMIT 1
    ) AS executor_access_dependencies ON TRUE
    LEFT JOIN LATERAL (
      SELECT 1 AS matched
      FROM refresh_token_families
      WHERE refresh_token_families.task_executor_id = task_executors.id
      LIMIT 1
    ) AS executor_family_dependencies ON TRUE
    LEFT JOIN LATERAL (
      SELECT 1 AS matched
      FROM refresh_token_families
      WHERE refresh_token_families.bound_runner_id = task_executors.id
      LIMIT 1
    ) AS application_family_dependencies ON TRUE
    LEFT JOIN LATERAL (
      SELECT 1 AS matched
      FROM device_authorizations
      WHERE device_authorizations.task_executor_id = task_executors.id
      LIMIT 1
    ) AS executor_authorization_dependencies ON TRUE
    LEFT JOIN LATERAL (
      SELECT 1 AS matched
      FROM device_authorizations
      WHERE device_authorizations.expected_task_executor_public_id = task_executors.public_id
        AND device_authorizations.status = 'connected'
      LIMIT 1
    ) AS executor_marker_dependencies ON TRUE
    LEFT JOIN LATERAL (
      SELECT 1 AS matched
      FROM agent_run_tasks
      WHERE agent_run_tasks.addressed_executor_id = task_executors.id
        AND agent_run_tasks.status IN ('dispatched', 'awaiting_input', 'needs_approval')
      LIMIT 1
    ) AS executor_addressed_work ON TRUE
    LEFT JOIN LATERAL (
      SELECT 1 AS matched
      FROM agent_run_tasks
      WHERE agent_run_tasks.claimed_by_executor_id = task_executors.id
        AND agent_run_tasks.status = 'dispatched'
      LIMIT 1
    ) AS executor_claimed_work ON TRUE
  SQL
  # A revoked executor is not reaped while a NON-TERMINAL row is addressed
  # to it or claimed by it; the two probes spell exactly the frontier and
  # claimant partial indexes' predicates, so each stays an index probe.
  # Terminal history nullifies at the reap (the FKs).
  NO_DURABLE_DEPENDENCIES_SQL = <<~SQL.squish.freeze
    executor_access_dependencies.matched IS NULL
      AND executor_family_dependencies.matched IS NULL
      AND application_family_dependencies.matched IS NULL
      AND executor_authorization_dependencies.matched IS NULL
      AND executor_marker_dependencies.matched IS NULL
      AND executor_addressed_work.matched IS NULL
      AND executor_claimed_work.matched IS NULL
  SQL
  # Human removal immediately closes new connection authority. The generation
  # mismatch survives restore and is the level-triggered work item the two
  # removal passes acknowledge. Both machine kinds answer to their manager
  # here — the literal list is TaskExecutor::MACHINE_KINDS.
  HUMAN_SHUTDOWN_PENDING_SQL = <<~SQL.squish.freeze
    (
      task_executors.executor_kind IN ('runner', 'tool_provider')
        AND EXISTS (
          SELECT 1 FROM users
          WHERE users.id = task_executors.manager_id
            AND users.managed_resource_shutdown_generation <>
              task_executors.applied_human_shutdown_generation
        )
    )
      OR
    (
      task_executors.executor_kind = 'agent_application'
        AND EXISTS (
          SELECT 1
          FROM users AS agents
          INNER JOIN users AS stewards
            ON stewards.id = agents.steward_id
          WHERE agents.id = task_executors.agent_id
            AND stewards.managed_resource_shutdown_generation <>
              task_executors.applied_human_shutdown_generation
        )
    )
  SQL

  # Pass (ii)'s gate: a non-terminal row this executor claimed, read off
  # the claimant index without a lock.
  def holds_claimed_work?
    AgentRunTask.where(claimed_by_executor_id: id, status: "dispatched").exists?
  end

  # The park sweep must finish pass (i) before acknowledging the Human's
  # generation; otherwise clearing the mismatch would hide remaining work.
  def holds_addressed_work?
    AgentRunTask.where(addressed_executor_id: id, status: UNCLAIMED_PARKED_STATUSES).exists?
  end

  class_methods do
    # Shutdown is capped at half the budget and reaping takes every unused
    # slot. Shutdown consumes scanned rows: the generation mismatch has no
    # index, so an idle pass is bounded by its source window.
    def converge(batch_size: BATCH_SIZE, shutdown_after_id: 0, reap_after_id: 0)
      shutdown_quota = (batch_size + 1) / 2
      shutdown_batch = converge_human_shutdown_batch(
        batch_size: shutdown_quota, after_id: shutdown_after_id
      )
      reap_batch = reap_batch(
        batch_size: batch_size - shutdown_batch.scanned,
        after_id: reap_after_id
      )
      Rails.logger.info "event=task_executors_converged " \
        "human_shutdowns_scanned=#{shutdown_batch.scanned} " \
        "human_shutdowns_converged=#{shutdown_batch.converged} " \
        "reap_scanned=#{reap_batch.scanned} reaped=#{reap_batch.reaped}"
      # The cursor is the pair the job hand-carries: the shutdown walk's, then the reap walk's.
      Sweeps::Pass.new(
        counts: {
          converged: shutdown_batch.converged,
          reaped: reap_batch.reaped,
          scanned: shutdown_batch.scanned + reap_batch.scanned,
        },
        cursor: [shutdown_batch.cursor, reap_batch.cursor],
        more: batch_size.positive? &&
          (!shutdown_batch.cursor.nil? || !reap_batch.cursor.nil?)
      )
    end

    # Old transport authority never revives on restore; addresses with no
    # family still acknowledge the episode before a re-pair. The window rides
    # the active-id partial frontier — revoked addresses owe nothing.
    def converge_human_shutdown_batch(batch_size:, after_id: 0)
      if after_id.nil?
        return ShutdownBatch.new(converged: 0, scanned: 0, cursor: nil)
      end
      return ShutdownBatch.new(converged: 0, scanned: 0, cursor: after_id) unless
        batch_size.positive?

      # Literal equality, not `live`'s NOT-revoked: only that proves the
      # active partial-index predicate at plan time.
      window = where("task_executors.status = 'active'").where(id: (after_id + 1)..)
        .order(:status, :id).limit(batch_size).pluck(:id)
      # `status` is re-applied at act time: a row revoked between the window
      # pluck and this load must not re-enter the sweep the old `live` scope
      # excluded it from.
      candidates = where(id: window, status: :active)
        .where(HUMAN_SHUTDOWN_PENDING_SQL)
        .includes(:manager, agent: :steward)
        .to_a
      # The park sweep owns the node-sized removal batches. Acknowledgement
      # waits while either addressed or claimed work remains.
      converged = candidates.count do |executor|
        human = executor.controlling_human
        executor.converge_human_shutdown(
          expected_human_id: human&.id,
          expected_generation: human&.managed_resource_shutdown_generation,
          expected_applied_generation: executor.applied_human_shutdown_generation
        ) == :converged
      end

      ShutdownBatch.new(
        converged: converged,
        scanned: window.length,
        cursor: window.length == batch_size ? window.last : nil
      )
    end
    private :converge_human_shutdown_batch

    # No counterpart revokes an agent's address when its lineage lapses: an
    # Agent is single-instance, so a returning person re-pairs the address
    # they had. Only an explicit revoke ends it.
    def reap(batch_size: BATCH_SIZE)
      reap_batch(batch_size:, after_id: 0).reaped
    end

    private

      # The window is materialized before any dependency probe, so blocked
      # markers consume budget and advance the cursor; the predicate repeats
      # after the row lock, before deletion.
      def reap_batch(batch_size:, after_id:)
        if after_id.nil?
          return ReapBatch.new(reaped: 0, scanned: 0, cursor: nil)
        end
        unless batch_size.positive?
          return ReapBatch.new(reaped: 0, scanned: 0, cursor: after_id)
        end

        reaped = 0
        window = []
        transaction do
          # Keep the closed status literal in SQL so PostgreSQL can prove the
          # predicate of the matching partial frontier at plan time.
          window = where("task_executors.status = 'revoked'").where(id: (after_id + 1)..)
            .order(:status, :id).limit(batch_size).pluck(:id)

          # Lock the whole window first, so a winning Connect or an FK insert
          # is visible before these probes or waits until after the delete.
          locked_ids = where(id: window, status: :revoked)
            .order(:id)
            .lock("FOR UPDATE OF task_executors SKIP LOCKED")
            .pluck(:id)

          # LIMIT inside each correlated probe keeps PostgreSQL from
          # decorrelating the bounded set into a hash scan of a child table.
          ids = where(id: locked_ids, status: :revoked)
            .joins(DURABLE_DEPENDENCY_JOINS_SQL)
            .where(NO_DURABLE_DEPENDENCIES_SQL)
            .order(:id)
            .pluck(:id)

          reaped = where(id: ids, status: :revoked).delete_all
        end

        ReapBatch.new(
          reaped: reaped,
          scanned: window.length,
          cursor: window.length == batch_size ? window.last : nil
        )
      end
  end
end
