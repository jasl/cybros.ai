module Workspaces
  # Collects tombstones 30 days after delete acceptance; the obligation gate
  # protects the model-work graph. Level-triggered and restartable.
  class Collect
    RETENTION_PERIOD = 30.days

    class << self
      def call(...)
        new(...).call
      end
    end

    # Two charge units: one per ordinary row, one per OneShot aggregate
    # with its whole bounded fan-out.
    def initialize(budget:, after_deleted_at: nil, after_id: 0)
      @budget = budget
      @after_deleted_at = Time.zone.iso8601(after_deleted_at) if after_deleted_at
      @after_id = after_id
    end

    def call
      @cutoff = RETENTION_PERIOD.ago
      @candidate_window = candidate_scope.to_a
      # Leaves-first, in the order the foreign keys dictate: deleting bodies
      # cascades their entries and upload joins, releasing uploads and
      # stranding fragments for their own reaper.
      processed = drain_model_work(@budget)
      processed += drain_store_entries(@budget - processed)
      processed += drain_documents(MemoryDocument, @budget - processed)
      processed += drain_documents(PromptDocument, @budget - processed)
      processed += drain_conversations(@budget - processed)
      processed += drain_agent_loops(@budget - processed)
      processed += drain_receipts(WorkspaceCommandReceipt, @budget - processed)
      processed += drain_receipts(ConversationCommandReceipt, @budget - processed)
      processed += drain_workspaces(@budget - processed)

      Sweeps::Pass.new(
        counts: { processed: processed },
        cursor: continuation_cursor(processed),
        # A full work budget repeats this window because a later drain stage
        # may not have run. Otherwise a full scan window advances even after
        # zero deletes, so blocked tombstones cannot hide the tail forever.
        more: @budget.positive? &&
          (processed == @budget || @candidate_window.length == @budget)
      )
    end

    private

      # `OneShots::Drain` owns the teardown order both routes share; this
      # owns only the gate.
      def drain_model_work(remaining)
        return 0 unless remaining.positive?

        # Materialized, not a subquery: a scalar id set enters through the
        # child index and can stop at `remaining`.
        OneShots::Drain.call(
          one_shot_ids: OneShot
            .where(workspace_id: collectible_workspace_ids)
            .order(:workspace_id, :id).limit(remaining).pluck(:id)
        )
      end

      # Each obligation is a correlated NOT EXISTS, never `NOT IN`: the
      # latter plans as a hashed SubPlan whose cost the budget does not bound.
      def collectible_workspace_ids
        eligible
          .where(id: candidate_ids)
          .where.not(nonterminal_model_work.arel.exists)
          .where.not(unsettled_attempt_work.arel.exists)
          .pluck(:id)
      end

      def nonterminal_model_work
        ModelInvocation.nonterminal
          .where("model_invocations.workspace_id = workspaces.id")
      end

      # A pending-settlement Attempt has a receipt writer that may still
      # run; reclaiming under it would discard permanent accounting evidence.
      def unsettled_attempt_work
        ModelInvocationAttempt.where(settlement_state: "pending")
          .joins(:model_invocation)
          .where("model_invocations.workspace_id = workspaces.id")
      end

      # The store's first rule: workspace-anchored rows drain with the
      # workspace. Conversation-anchored rows are the conversation stage's,
      # user-anchored rows are nobody's here.
      def drain_store_entries(remaining)
        return 0 unless remaining.positive?

        # Materialized before the DELETE like every other drain application:
        # a LIMIT left as a subquery invites the outer DELETE to hash the id
        # set and scan the whole table instead of probing the primary key.
        leaf_ids = StoreEntry
          .joins(:workspace)
          .where(workspace_id: candidate_ids)
          .order("workspaces.deleted_at", "workspaces.id", "store_entries.id")
          .limit(remaining)
          .pluck(:id)

        StoreEntry.where(id: leaf_ids).delete_all
      end

      # The final bulk delete does not run Workspace's association callbacks.
      # Charge workspace document pointers/slots as leaves; immutable memory
      # versions remain with their other readers or the orphan-version sweep.
      def drain_documents(model, remaining)
        return 0 unless remaining.positive?

        ids = model.where(workspace_id: candidate_ids)
          .order(:workspace_id, :id).limit(remaining).pluck(:id)
        model.where(id: ids).delete_all
      end

      # The conversation stage, or a workspace that hosted one is
      # uncollectible behind the RESTRICT FKs. Descending id is the fork
      # trees' topological order; conversation lock first, recheck under it, a lost pin is a skip.
      # The store's second rule: a conversation's own store rows leave with
      # it here, through `StoreHost`'s cascade under `destroy!` — the same
      # way the root reaper (Conversations::Reap) takes them.
      def drain_conversations(remaining)
        return 0 unless remaining.positive?

        ids = Conversation
          .where(workspace_id: candidate_ids)
          .where.not(descendant_conversation_pins.arel.exists)
          .where.not(nonterminal_conversation_work.arel.exists)
          .where.not(unsettled_conversation_attempts.arel.exists)
          .order(id: :desc)
          .limit(remaining)
          .pluck(:id)
        ids.count { |id| drain_conversation(id) }
      end

      def drain_conversation(id)
        Conversation.transaction(requires_new: true) do
          locked = Conversation.lock.find_by(id: id)
          next false if locked.nil?

          Conversations::Reap.destroy_aggregate(locked)
        end
      rescue ActiveRecord::StatementInvalid => error
        case error.cause
        when PG::RestrictViolation
          # A descendant pinned this row between the pluck and the lock;
          # level-triggered — rediscovered when the pin dies.
          false
        else
          raise
        end
      end

      def descendant_conversation_pins
        ConversationAncestry.where(
          "conversation_ancestries.ancestor_conversation_id = conversations.id"
        )
      end

      def nonterminal_conversation_work
        ModelInvocation.nonterminal.where(
          "model_invocations.conversation_id = conversations.id"
        )
      end

      def unsettled_conversation_attempts
        ModelInvocationAttempt.where(settlement_state: "pending")
          .joins(:model_invocation)
          .where("model_invocations.conversation_id = conversations.id")
      end

      # The agent-loop stage, for the same reason. Workspace-driven, so it
      # ignores `tombstoned_at`: this answers the container's delete, not the user's.
      def drain_agent_loops(remaining)
        return 0 unless remaining.positive?

        ids = AgentLoop
          .where(workspace_id: candidate_ids)
          .where.not(nonterminal_loop_work.arel.exists)
          .where.not(unsettled_loop_attempts.arel.exists)
          .order(id: :desc)
          .limit(remaining)
          .pluck(:id)
        ids.count { |id| drain_agent_loop(id) }
      end

      def drain_agent_loop(id)
        stop_agent_loop(id)
        AgentLoop.transaction(requires_new: true) do
          locked = AgentLoop.lock.find_by(id: id)
          next false if locked.nil?

          AgentLoops::Reap.destroy_aggregate(locked)
        end
      rescue ActiveRecord::StatementInvalid => error
        case error.cause
        when PG::RestrictViolation
          # Level-triggered skip, the conversation stage's rule: a row that
          # grew a fence between the pluck and the lock is rediscovered.
          false
        else
          raise
        end
      end

      def stop_agent_loop(id)
        # Parks and delegated work have no live invocation to fence this
        # stage. Commit their canonical stop before teardown: a standalone
        # loop is also its narration host, which must exist at that commit.
        AgentLoop.transaction(requires_new: true) do
          locked = AgentLoop.lock.find_by(id: id)
          AgentLoops::Stop.stop_now(locked) if locked && !locked.terminal?
        end
      end

      def nonterminal_loop_work
        ModelInvocation.nonterminal.where(
          "model_invocations.agent_loop_id = agent_loops.id"
        )
      end

      def unsettled_loop_attempts
        ModelInvocationAttempt.where(settlement_state: "pending")
          .joins(:model_invocation)
          .where("model_invocations.agent_loop_id = agent_loops.id")
      end

      # Hosted receipts deliberately outlive their weak host references. Drain
      # both families within this budget even when their age reaper has lagged.
      def drain_receipts(model, remaining)
        return 0 unless remaining.positive?

        leaf_ids = model
          .where(workspace_id: candidate_ids)
          .order(:workspace_id, :id)
          .limit(remaining)
          .pluck(:id)

        model.where(id: leaf_ids).delete_all
      end

      def drain_workspaces(remaining)
        return 0 unless remaining.positive?

        # The store's third rule: `store_entries` is the FK association, so
        # this gate sees workspace-anchored rows ONLY by construction — a
        # conversation-anchored row carries no `workspace_id`, and a person's
        # profile store outlives every workspace they used. A column that
        # ever put `workspace_id` on conversation rows would silently
        # re-gate this collect.
        workspace_ids = eligible
          .where(id: candidate_ids)
          .where.missing(:store_entries)
          .where.missing(:memory_documents)
          .where.missing(:prompt_documents)
          .where(<<~SQL.squish)
            NOT EXISTS (
              SELECT 1
              FROM workspace_command_receipts
              WHERE workspace_command_receipts.workspace_id = workspaces.id
            )
          SQL
          .where(<<~SQL.squish)
            NOT EXISTS (
              SELECT 1
              FROM conversation_command_receipts
              WHERE conversation_command_receipts.workspace_id = workspaces.id
            )
          SQL
          .where(<<~SQL.squish)
            NOT EXISTS (
              SELECT 1 FROM one_shots WHERE one_shots.workspace_id = workspaces.id
            )
          SQL
          .where(<<~SQL.squish)
            NOT EXISTS (
              SELECT 1 FROM conversations WHERE conversations.workspace_id = workspaces.id
            )
          SQL
          .where(<<~SQL.squish)
            NOT EXISTS (
              SELECT 1 FROM agent_loops WHERE agent_loops.workspace_id = workspaces.id
            )
          SQL
          .limit(remaining)
          .pluck(:id)

        Workspace.where(id: workspace_ids).delete_all
      end

      # The partial `(deleted_at, id)` index and matching cursor bound each
      # candidate scan by the caller budget. A recurring pass starts without
      # a cursor and therefore revisits rows skipped behind a live obligation.
      def candidate_ids
        @candidate_ids ||= @candidate_window.map(&:id)
      end

      def candidate_scope
        relation = eligible
        if @after_deleted_at
          relation = relation.where(
            "(workspaces.deleted_at, workspaces.id) > (?, ?)",
            @after_deleted_at, @after_id
          )
        end
        relation.limit(@budget).select(:id, :deleted_at)
      end

      def continuation_cursor(processed)
        if processed == @budget || @candidate_window.empty?
          [@after_deleted_at&.iso8601(6), @after_id]
        else
          last_candidate = @candidate_window.last
          [last_candidate.deleted_at.iso8601(6), last_candidate.id]
        end
      end

      def eligible
        eligible_scope.order(:deleted_at, :id)
      end

      def eligible_scope
        Workspace.where(state: :deleted).where(deleted_at: ..@cutoff)
      end
  end
end
