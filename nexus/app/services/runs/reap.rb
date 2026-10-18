module Runs
  # Reclaims aged tombstones leaves-first by hand: the graph's guards are
  # `restrict_with_exception`, and reaping is the one sanctioned path
  # through them once nothing can be running.
  class Reap
    class << self
      def call(...) = new(...).call

      # The one teardown order, shared with the workspace collector so the
      # two routes cannot drift: pointers before the rows they point at,
      # nodes before the invocations they name.
      def destroy_aggregate(run)
        return false if Delegations.retained?(run)

        destroy_details(run)
        # The hosted inputs it still holds, bodies included, cascade with the row.
        run.destroy!
        true
      end

      # Shared leaves-first teardown. Retention keeps the loop identity and
      # terminal state; a tombstone additionally removes that shell.
      def destroy_details(run)
        run.update!(deliverable_node_id: nil)
        # A plain relation, NOT the association proxy: `delete_all` on a
        # RESTRICT association nullifies the owner key instead of deleting,
        # which a NOT NULL column then refuses.
        RunEdge.where(run_id: run.id).in_batches(of: 500).delete_all
        # A generated child is inserted after its immutable expansion parent.
        # Destroy children first so the ownership FK never needs to be cleared.
        run.tasks.find_each(batch_size: 100, order: :desc, &:destroy!)
        run.model_invocations.in_batches(of: 100) do |invocations|
          ModelInvocations::DrainSettled.call(invocations)
        end
      end
    end

    def initialize(batch:, after_tombstoned_at: nil, after_id: 0)
      @batch = batch
      @cutoff = Run::RETENTION_PERIOD.ago
      @after_tombstoned_at = Time.zone.iso8601(after_tombstoned_at) if after_tombstoned_at
      @after_id = after_id
    end

    def call
      rows = candidates.select(:id, :tombstoned_at).to_a
      reaped = rows.count { |row| reap_one(row.id) }

      Sweeps::Pass.new(
        counts: { scanned: rows.length, reaped: reaped },
        cursor: rows.last && [rows.last.tombstoned_at.iso8601(6), rows.last.id],
        more: @batch.positive? && rows.length == @batch
      )
    end

    private

      def candidates
        scope = Run.tombstoned_before(@cutoff)
          .where.not(nonterminal_work.arel.exists)
          .where.not(unsettled_attempt_work.arel.exists)
        if @after_tombstoned_at
          scope = scope.where("(runs.tombstoned_at, runs.id) > (?, ?)",
            @after_tombstoned_at, @after_id)
        end
        scope
          .order(:tombstoned_at, :id)
          .limit(@batch)
      end

      def nonterminal_work
        ModelInvocation.nonterminal.where(
          "model_invocations.run_id = runs.id"
        )
      end

      # A pending settlement has a receipt writer that may not have run yet
      # and holds no invocation lock on the discarded path — reclaiming
      # under it would strand a late receipt (the InferenceRequests::Reap lesson).
      def unsettled_attempt_work
        ModelInvocationAttempt.where(settlement_state: "pending")
          .joins(:model_invocation)
          .where("model_invocations.run_id = runs.id")
      end

      def reap_one(id)
        ApplicationRecord.transaction(requires_new: true) do
          run = Run.lock.find_by(id: id)
          next false if run.nil?
          # Re-checked under the lock: a loop that stopped being eligible
          # while the batch was scanned is a SKIP, rediscovered later.
          next false unless run.tombstoned? &&
            run.tombstoned_at <= @cutoff
          next false if ApplicationRecord.uncached do
            ModelInvocation.where(run_id: id).nonterminal.exists?
          end

          self.class.destroy_aggregate(run)
        end
      rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::InvalidForeignKey => error
        # Defense in depth behind the row lock: a row that grew a
        # dependent between the check and the delete stays for the next
        # pass rather than aborting the batch.
        Rails.error.report(error, handled: true,
          context: { event: "run_reap_skipped", run_id: id })
        false
      end
  end
end
