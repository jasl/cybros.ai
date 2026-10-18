module UsageBudgets
  module Projection
    def self.budget(budget, at: Time.current)
      {
        public_id: budget.public_id,
        user_public_id: budget.user_public_id,
        user_kind: budget.user_kind,
        credited_amount: budget.credited_amount.to_s("F"),
        debited_amount: budget.debited_amount.to_s("F"),
        headroom: budget.headroom.to_s("F"),
        cost_unit: budget.account.cost_unit,
        starts_at: budget.starts_at,
        expires_at: budget.expires_at,
        revoked_at: budget.revoked_at,
        revoked_by_public_id: budget.revoked_by_public_id,
        revoke_reason: budget.revoke_reason,
        usable: budget.usable_at?(at),
      }
    end

    # Financial reads expose amounts and Human adjustments, without receipt identities
    # or kernel operation keys that could become activity links.
    def self.entry(entry)
      {
        public_id: entry.public_id, sequence: entry.entry_sequence, kind: entry.kind,
        amount: entry.amount.to_s("F"), cost_unit: entry.cost_unit,
        actor_public_id: entry.actor_public_id, reason: entry.reason, created_at: entry.created_at,
      }
    end

    def self.adjustment_entry(entry)
      {
        sequence: entry.entry_sequence, kind: entry.kind, amount: entry.amount.to_s("F"),
        reason: entry.reason, operation_key: entry.operation_key, created_at: entry.created_at,
      }
    end
  end
end
