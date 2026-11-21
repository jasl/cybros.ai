module Runs
  # A sent request keeps its execution owner, not its reusable child container.
  # The same weak stamp belongs to a queued receipt and its materialized turn.
  # A missing owner owes no new execution. A human regeneration is a new request;
  # only position zero and its kernel fallback inherit the original obligation.
  module SourceWork
    module_function

    def with_source(public_id)
      source = Run.find_by(public_id: public_id) if public_id
      source ? source.with_lock { yield source } : yield(nil)
    end

    # The caller holds the destination Conversation. Acquire every selected
    # owner in database order before consuming any receipt or body.
    def with_sources(public_ids)
      sources = Run.where(public_id: public_ids.compact.uniq).order(:id).lock.to_a
      yield sources.index_by(&:public_id)
    end

    def stopped?(public_id, source)
      public_id.present? && (source.nil? || source.stopped? || source.canceling? || source.canceled? || stopped_source?(source))
    end

    # Graceful cancellation drains tasks already dispatched by this owner.
    # A source cut still revokes a derived request, and a replacement marker
    # fences execution before its asynchronous drain changes the status.
    def execution_stopped?(run)
      run.stopped? || stopped_source?(run)
    end

    def source_of(variant)
      turn = variant.turn
      return if turn.source_released_at || turn.forked_from_turn_public_id || turn.sender_run_public_id.nil? || turn.communication_kind == "message"
      return unless variant.position.zero? || (variant.fallback? && variant.origin_variant&.position == 0)

      turn.sender_run_public_id
    end

    # Called under the target loop's arbiter. This reads an irreversible fact;
    # it never takes a second loop in reverse order. An overlapping source cut
    # is recovered by the existing bounded live-loop scheduler window.
    def stopped_source?(run)
      return false if run.standalone?

      stopped_source_ids([run.id]).any?
    end

    # Carry each inspected Run's identity through its own chain. A missing
    # parent still revokes the child. A completed, unstopped intermediate
    # owner still passes its ancestor's Stop on. The same query fences one
    # execution under lock and discovers cuts for a bounded recovery page.
    def stopped_source_ids(run_ids)
      return [] if run_ids.empty?

      sql = ApplicationRecord.sanitize_sql_array([<<~SQL, run_ids, run_ids.length])
        WITH RECURSIVE ownership AS (
          SELECT id AS root_id, id, variant_id, stopped_at, status
          FROM runs WHERE id IN (?)
          UNION ALL
          (SELECT child.root_id, parent.id, parent.variant_id, parent.stopped_at, parent.status
          FROM ownership child
          CROSS JOIN LATERAL (
            -- Keep lookup rooted at this child even if most historical turns have a sender.
            SELECT turn.sender_run_public_id
            FROM variants variant
            JOIN turns turn ON turn.id = variant.turn_id
            LEFT JOIN variants origin ON origin.id = variant.origin_variant_id
            WHERE variant.id = child.variant_id
              AND turn.sender_run_public_id IS NOT NULL AND turn.forked_from_turn_public_id IS NULL
              AND turn.source_released_at IS NULL
              AND turn.communication_kind IS DISTINCT FROM 'message'
              AND (variant.position = 0 OR (variant.source = 'fallback' AND origin.position = 0))
            OFFSET 0
          ) source
          LEFT JOIN runs parent ON parent.public_id = source.sender_run_public_id
          -- One parent at most per child. Bound the estimate of each recursive
          -- generation by its roots to avoid JIT compilation on an ordinary page.
          LIMIT ?)
        )
        SELECT DISTINCT root_id FROM ownership
        WHERE id IS NULL OR (id <> root_id AND (stopped_at IS NOT NULL OR status IN ('canceling', 'canceled')))
      SQL
      ApplicationRecord.lease_connection.select_values(sql)
    end

    def stopped_variant_source?(variant)
      public_id = source_of(variant)
      return false unless public_id

      stopped?(public_id, Run.find_by(public_id: public_id))
    end
  end
end
