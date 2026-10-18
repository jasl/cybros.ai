class Conversation
  # A member-adjustable admission guard over this conversation's own known
  # usage. The receipt ledger owns spend; no reservation or exhausted state.
  module CostLimit
    extend ActiveSupport::Concern

    included do
      validate :cost_limit_is_exact
    end

    # The presenter supplies the subtotal it already read. Admission reads
    # the same receipt-transactional cache, without locking this aggregate.
    def cost_limit_reached?(cost_amount: nil)
      return false if cost_limit.nil?

      cost_amount ||= ModelUsageSummary.where(
        subject_kind: "conversation", subject_id: id
      ).pick(:cost_amount) || 0
      cost_amount.to_d >= cost_limit
    end

    private

      # Validate the submitted value before Active Record's decimal cast can
      # round it to the column scale or silently turn malformed text into zero.
      def cost_limit_is_exact
        raw = cost_limit_before_type_cast
        return if raw.nil?

        amount = BigDecimal(raw.to_s, exception: false)
        unless amount&.finite? && !amount.negative? &&
            amount < BigDecimal("1e20") && amount == amount.round(18)
          errors.add(:cost_limit, :invalid)
          return
        end

        errors.add(:cost_limit, :cost_unit_unconfigured) if account.cost_unit.blank?
      end
  end
end
