module UsageRecords
  # Settles receipts into payers' ledgers out of band (bounded overspend). Every scanned receipt is
  # flagged, unknown cost is counted and never summed as zero, and the charge never refuses — the
  # provider was already paid.
  class SettleSpend
    DEFAULT_BATCH_SIZE = 1_000

    Charge = Data.define(:budget, :receipt, :operation_key)
    BudgetUpdate = Data.define(:budget, :amount, :last_entry_sequence)

    def self.call(...) = new(...).call

    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      @batch_size = batch_size
    end

    def call
      UsageRecord.transaction do
        settled_at = DatabaseClock.now
        receipts = UsageRecord.unsettled
          .order(:recorded_at, :id)
          .lock("FOR UPDATE SKIP LOCKED")
          .limit(@batch_size)
          .to_a
        if receipts.empty?
          next Sweeps::Pass.new(counts: { settled: 0, charged: 0, unknown_cost: 0 }, more: false)
        end

        charged = charge_by_payer(receipts)
        UsageRecord.where(id: receipts.map(&:id)).update_all(
          spend_settled_at: settled_at, updated_at: settled_at
        )
        Sweeps::Pass.new(
          counts: {
            settled: receipts.length,
            charged: charged,
            unknown_cost: receipts.count { |receipt| unknown_cost?(receipt) },
          },
          more: receipts.length == @batch_size
        )
      end
    end

    private

      # Group by payer, lock all touched Human payers in one ordered query,
      # then append the batch's charge entries under each usable budget.
      def charge_by_payer(receipts)
        chargeable = receipts.select { |receipt| chargeable?(receipt) }
        return 0 if chargeable.empty?

        groups = chargeable.group_by(&:payer_user_public_id)
        payers = lock_payers(groups.keys)
        # Asked of the clock after the payer locks are held: a budget writer
        # may have spent our lock wait moving the windows.
        locked_at = DatabaseClock.now

        budgets = lock_usable_budgets(payers.values, locked_at)
        charges = planned_charges(groups, payers: payers, budgets: budgets)
        append_charges(charges, at: locked_at)
      end

      # Every payer is already a Human, so one ascending-id SELECT FOR UPDATE
      # locks them all.
      def lock_payers(public_ids)
        User.where(public_id: public_ids)
          .order(:id)
          .lock
          .index_by(&:public_id)
      end

      # The scan is status-blind (billed is billed) but the audit count is
      # not: a failed attempt with no usage is a transient, and a retry storm
      # must not drown the catalog-outage signal.
      def unknown_cost?(receipt)
        return false unless receipt.cost_amount.nil?

        receipt.status == UsageRecord::ABANDONED ||
          (receipt.admission_shape == "priced" &&
            UsageRecord::BILLABLE_STATUSES.include?(receipt.status))
      end

      def chargeable?(receipt)
        receipt.admission_shape == "priced" &&
          receipt.cost_amount.present? && receipt.cost_amount.positive? &&
          receipt.payer_user_public_id.present?
      end

      # User locks above freeze every budget window writer. Lock the selected
      # budgets in id order so overlapping settlement batches agree on their
      # within-table order too.
      def lock_usable_budgets(payers, locked_at)
        UsageBudget.usable_at(locked_at)
          .where(user_id: payers.map(&:id))
          .includes(:account)
          .order(:id)
          .lock
          .to_a
      end

      def planned_charges(groups, payers:, budgets:)
        payers_by_id = payers.values.index_by(&:id)

        budgets.flat_map do |budget|
          payer = payers_by_id.fetch(budget.user_id)
          groups.fetch(payer.public_id).filter_map do |receipt|
            if receipt.cost_unit == budget.account.cost_unit
              Charge.new(
                budget: budget, receipt: receipt,
                operation_key: "settle:#{receipt.public_id}"
              )
            end
          end
        end
      end

      # Operation keys are scoped to the payer across ALL of their windows.
      # Fetch the bounded batch's existing keys once; the held User locks make
      # the answer stable until the entries and heads commit.
      def append_charges(charges, at:)
        return 0 if charges.empty?

        existing = existing_operation_keys(charges)
        fresh = charges.reject do |charge|
          existing.key?([charge.budget.user_id, charge.operation_key])
        end
        return 0 if fresh.empty?

        rows, updates = entry_rows_and_head_updates(fresh, at: at)
        UsageBudgetEntry.insert_all!(rows)
        update_budget_heads(updates, at: at)
        rows.length
      end

      def existing_operation_keys(charges)
        UsageBudgetEntry
          .joins(:usage_budget)
          .where(
            usage_budgets: { user_id: charges.map { |charge| charge.budget.user_id }.uniq },
            operation_key: charges.map(&:operation_key)
          )
          .pluck("usage_budgets.user_id", "usage_budget_entries.operation_key")
          .to_h { |user_id, operation_key| [[user_id, operation_key], true] }
      end

      def entry_rows_and_head_updates(charges, at:)
        rows = []
        updates = charges.group_by { |charge| charge.budget.id }.map do |_budget_id, group|
          budget = group.first.budget
          sequence = budget.last_entry_sequence
          amount = BigDecimal(0)

          group.each do |charge|
            sequence += 1
            amount += charge.receipt.cost_amount
            rows << {
              usage_budget_id: budget.id,
              account_public_id: budget.account.public_id,
              user_public_id: budget.user_public_id,
              entry_sequence: sequence,
              kind: "charge",
              amount: charge.receipt.cost_amount,
              cost_unit: charge.receipt.cost_unit,
              usage_record_public_id: charge.receipt.public_id,
              operation_key: charge.operation_key,
              created_at: at,
              updated_at: at,
            }
          end

          BudgetUpdate.new(
            budget: budget, amount: amount, last_entry_sequence: sequence
          )
        end
        [rows, updates]
      end

      # The budget rows are already locked and every delta came from a positive
      # priced receipt. One CASE update preserves the append/head atomicity
      # without rewriting the same materialized head once per receipt.
      def update_budget_heads(updates, at:)
        table = UsageBudget.arel_table
        amounts = Arel::Nodes::Case.new(table[:id])
        sequences = Arel::Nodes::Case.new(table[:id])
        updates.each do |update|
          amounts.when(update.budget.id).then(update.amount)
          sequences.when(update.budget.id).then(update.last_entry_sequence)
        end

        UsageBudget.where(id: updates.map { |update| update.budget.id }).update_all(
          debited_amount: table[:debited_amount] + amounts,
          last_entry_sequence: sequences,
          updated_at: at
        )
      end
  end
end
