module ModelInvocations
  # The one public error shape both surfaces project through. A declined
  # answer is the run's failure though the call completed. Otherwise the
  # invocation's key wins except where the budget was spent — ours
  # (`attempt_budget_spent`) or the provider's overload on every attempt:
  # then the latest receipt's code, with the budget as a present-or-absent caveat.
  class PublicError
    BUDGET_SPENT = "attempt_budget_spent".freeze
    SPENT_KEYS = [BUDGET_SPENT, ModelInvocation::OVERLOADED_KEY].freeze

    def self.render(invocation, receipt)
      return { "code" => ModelInvocation::DECLINED_KEY } if invocation.declined?
      return budget_spent(receipt) if SPENT_KEYS.include?(invocation.failure_reason_key)

      code = invocation.failure_reason_key.presence || receipt&.error_code.presence
      code && { "code" => code }
    end

    # A spent budget with no receipt is not reachable today; the caller is
    # owed a code either way.
    def self.budget_spent(receipt)
      {
        "code" => receipt&.error_code.presence || BUDGET_SPENT,
        "attempt_budget_spent" => true,
      }
    end
    private_class_method :budget_spent
  end
end
