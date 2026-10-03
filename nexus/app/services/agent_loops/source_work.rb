module AgentLoops
  # A sent request keeps its execution owner, not its reusable child container.
  # The same weak stamp belongs to a queued receipt and its materialized turn.
  # A missing owner owes no new execution. A human regeneration is a new request;
  # only position zero and its kernel fallback inherit the original obligation.
  module SourceWork
    module_function

    def with_source(public_id)
      source = AgentLoop.find_by(public_id: public_id) if public_id
      source ? source.with_lock { yield source } : yield(nil)
    end

    # The caller holds the destination Conversation. Acquire every selected
    # owner in database order before consuming any receipt or body.
    def with_sources(public_ids)
      sources = AgentLoop.where(public_id: public_ids.compact.uniq).order(:id).lock.to_a
      yield sources.index_by(&:public_id)
    end

    def stopped?(public_id, source)
      public_id.present? && (source.nil? || source.stopped? || source.canceling? || source.canceled? || stopped_source?(source))
    end

    # Graceful cancellation drains tasks already dispatched by this owner.
    # A source cut still revokes a derived request, and a replacement marker
    # fences execution before its asynchronous drain changes the status.
    def execution_stopped?(agent_loop)
      agent_loop.stopped? || stopped_source?(agent_loop)
    end

    def source_of(variant)
      turn = variant.conversation_turn
      return if turn.forked_from_turn_public_id || turn.sender_agent_loop_public_id.nil?
      return unless variant.position.zero? || (variant.fallback? && variant.origin_variant&.position == 0)

      turn.sender_agent_loop_public_id
    end

    # Called under the target loop's arbiter. This reads an irreversible fact;
    # it never takes a second loop in reverse order. An overlapping source cut
    # is recovered by the existing bounded live-loop scheduler window.
    def stopped_source?(agent_loop)
      return false if agent_loop.standalone?

      # Each recursive step follows immutable ownership to an older execution,
      # through indexed variant/turn keys and the source loop's unique UUID.
      # Completed intermediate owners remain in this chain: no live-work scan
      # or asynchronous propagation is needed to fence their pending receipts.
      sql = ApplicationRecord.sanitize_sql_array([<<~SQL, agent_loop.public_id, agent_loop.id])
        WITH RECURSIVE ownership AS (
          SELECT id, conversation_turn_variant_id, stopped_at, status
          FROM agent_loops WHERE public_id = ?
          UNION ALL
          SELECT parent.id, parent.conversation_turn_variant_id, parent.stopped_at, parent.status
          FROM ownership child
          JOIN conversation_turn_variants variant ON variant.id = child.conversation_turn_variant_id
          JOIN conversation_turns turn ON turn.id = variant.conversation_turn_id
          LEFT JOIN conversation_turn_variants origin ON origin.id = variant.origin_variant_id
          LEFT JOIN agent_loops parent ON parent.public_id = turn.sender_agent_loop_public_id
          WHERE turn.sender_agent_loop_public_id IS NOT NULL AND turn.forked_from_turn_public_id IS NULL
            AND (variant.position = 0 OR (variant.source = 'fallback' AND origin.position = 0))
        )
        SELECT EXISTS (SELECT 1 FROM ownership
          WHERE ((stopped_at IS NOT NULL OR status IN ('canceling', 'canceled')) AND id <> ?) OR id IS NULL)
      SQL
      ApplicationRecord.lease_connection.select_value(sql)
    end

    def stopped_variant_source?(variant)
      public_id = source_of(variant)
      return false unless public_id

      stopped?(public_id, AgentLoop.find_by(public_id: public_id))
    end
  end
end
