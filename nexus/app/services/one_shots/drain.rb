module OneShots
  # Leaves-first teardown shared by the Workspace collector and the OneShot
  # reaper, so neither carries its own copy of the order. Who may die is
  # the caller's question; this answers only how.
  class Drain
    def self.call(...) = new(...).call

    def initialize(one_shot_ids:)
      @one_shot_ids = one_shot_ids
    end

    # Each aggregate gets its own transaction. This preserves atomic teardown
    # without turning a scheduled run's aggregate budget into one transaction
    # whose row count is budget times the bounded content fan-out.
    def call
      @one_shot_ids.sum { |one_shot_id| drain(one_shot_id) }
    end

    private

      def drain(one_shot_id)
        ApplicationRecord.transaction do
          # Scans are unlocked and the two callers may overlap, so the
          # immutable owner is the claim lock.
          one_shot = OneShot.lock.find_by(id: one_shot_id)
          next 0 unless one_shot

          # Both owners' bodies join one set. Body deletion lets the database
          # cascade its entries and upload joins; fragments remain available
          # for the age-gated orphan reaper.
          invocation_ids = ModelInvocation.where(one_shot_id: one_shot.id)
            .order(:id).lock.pluck(:id)
          body_ids = ContentBody
            .where(one_shot_id: one_shot.id)
            .or(ContentBody.where(model_invocation_id: invocation_ids))
            .pluck(:id)
          ContentBody.where(id: body_ids).delete_all

          # The replay stream dies with the aggregate, child-first so the FKs
          # never argue: items, envelopes, cursor. Receipts are the plane
          # that outlives; events are not it.
          OneShotEventItem.where(one_shot_id: one_shot.id).delete_all
          OneShotEvent.where(one_shot_id: one_shot.id).delete_all
          OneShotEventCursor.where(one_shot_id: one_shot.id).delete_all

          # The subject-keyed rollup goes with its subject; durable accounting
          # truth lives in usage_records and is untouched.
          ModelUsageSummary.where(
            subject_kind: ModelUsageSummary::SUBJECT_KINDS.fetch(:one_shot),
            subject_id: one_shot.id
          ).delete_all

          # Attempts go first, explicitly: their FK is RESTRICT so no
          # incidental parent delete can erase the only record a provider was
          # asked. The money is in usage_records.
          ModelInvocation.purge_output_files_later(invocation_ids)

          # Already locked in id order by the discovery read, an explicit
          # locking SELECT the ladder guard can see.
          ModelInvocationAttempt.where(model_invocation_id: invocation_ids).delete_all
          ModelInvocation.where(id: invocation_ids).delete_all
          OneShotCreateReceipt.where(one_shot_id: one_shot.id).delete_all
          OneShot.where(id: one_shot.id).delete_all
        end
      end
  end
end
