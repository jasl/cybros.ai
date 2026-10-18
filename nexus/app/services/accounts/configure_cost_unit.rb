module Accounts
  # Configure-once cost unit: one nil-only compare-and-set, never a lock on
  # the Account root, so child FK inserts cannot contend with this rare setting.
  class ConfigureCostUnit
    Result = Data.define(:outcome) do
      def configured? = outcome == :configured
      def already_configured? = outcome == :already_configured
      def conflict? = outcome == :conflict
      def invalid? = outcome == :invalid
    end

    class << self
      def call(account:, cost_unit:)
        value = Account.normalize_value_for(:cost_unit, cost_unit.to_s)
        if value.blank? || value.length > Account::COST_UNIT_MAX_LENGTH
          return Result.new(outcome: :invalid)
        end

        if Account.where(id: account.id, cost_unit: nil).update_all(cost_unit: value) == 1
          Result.new(outcome: :configured)
        else
          current = Account.where(id: account.id).pick(:cost_unit)
          Result.new(outcome: current == value ? :already_configured : :conflict)
        end
      end
    end
  end
end
