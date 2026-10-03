# The append-only ledger fact — one immutable row per grant, adjustment,
# charge or consumption; the parent's materialized head is the enforcement
# snapshot this ledger is the truth of.
class UsageBudgetEntry < ApplicationRecord
  HUMAN_AUTHORED_KINDS = %w[initial_grant credit_adjustment debit_adjustment].freeze
  KERNEL_KINDS = %w[charge allowance_consumption].freeze
  KINDS = (HUMAN_AUTHORED_KINDS + KERNEL_KINDS).freeze

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :usage_budget

  validates :entry_sequence, numericality: { only_integer: true, greater_than: 0 }
  validates :kind, inclusion: { in: KINDS }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :cost_unit, presence: true

  # Human-authored kinds carry their actor and no kernel identity; kernel
  # kinds derive from the immutable receipt they charge.
  validates :actor_public_id, presence: true, if: -> { HUMAN_AUTHORED_KINDS.include?(kind) }
  validates :usage_record_public_id, presence: true, if: -> { KERNEL_KINDS.include?(kind) }
  validate :human_authored_entry_carries_no_receipt

  # Append-only: every column is frozen at insert.
  def readonly? = persisted?

  private

    def human_authored_entry_carries_no_receipt
      if HUMAN_AUTHORED_KINDS.include?(kind) && usage_record_public_id
        errors.add(:base, :human_authored_carries_receipt)
      end
    end
end
