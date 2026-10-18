module BudgetWriting
  extend ActiveSupport::Concern

  ABSENCE_REFUSALS = [].freeze
  REFUSAL_CODES = {
    not_authorized: :user_not_administrable, invalid: :validation_failed,
    unit_unconfigured: :account_unit_unconfigured, overlap: :budget_window_overlap,
    starts_at_taken: :budget_window_overlap, insufficient_headroom: :budget_insufficient_headroom,
    already_revoked: :budget_already_revoked, conflict: :idempotency_envelope_mismatch,
  }.freeze
  REFUSAL_STATUSES = {
    user_not_administrable: :forbidden, budget_window_overlap: :conflict,
    budget_insufficient_headroom: :conflict, budget_already_revoked: :conflict,
  }.freeze
  REFUSAL_DEFAULT_STATUS = :unprocessable_content
  REFUSAL_MESSAGES = {
    user_not_administrable: "This member's budget cannot be managed by this caller",
    account_unit_unconfigured: "Configure the account cost unit before opening budgets",
    budget_window_overlap: "The window overlaps an existing usable budget",
    budget_insufficient_headroom: "The debit exceeds the budget's remaining headroom",
    budget_already_revoked: "This budget is already revoked",
    idempotency_envelope_mismatch: "This Idempotency-Key was used with a different request",
  }.freeze

  def create
    key = required_operation_key or return
    fields = params.expect(budget: [:amount, :starts_at, :expires_at, :reason])
    result = UsageBudgets::Open.call(
      actor: Current.user, target: budget_target, amount: fields[:amount],
      starts_at: budget_time(fields[:starts_at], :starts_at),
      expires_at: fields[:expires_at].nil? ? nil : budget_time(fields[:expires_at], :expires_at),
      operation_key: key, reason: fields[:reason]
    )
    if result.opened?
      render json: { budget: budget_projection(result.budget) }, status: :created
    else
      render_refusal(result.outcome)
    end
  end

  def update
    key = required_operation_key or return
    budget = find_budget
    fields = params.expect(budget: [:kind, :amount, :reason])
    result = UsageBudgets::Adjust.call(
      actor: Current.user, budget: budget, kind: fields[:kind].to_s.presence&.to_sym,
      amount: fields[:amount], operation_key: key, reason: fields[:reason]
    )
    if result.adjusted?
      render json: { budget: budget_projection(budget.reload), entry: entry_projection(result.entry) }
    else
      render_refusal(result.outcome)
    end
  end

  private

    def revoke_budget
      key = required_operation_key or return
      budget = find_budget
      reason = params.fetch(:revocation, {}).permit(:reason)[:reason]
      result = UsageBudgets::Revoke.call(actor: Current.user, budget: budget, operation_key: key, reason: reason)
      if result.revoked?
        render json: { budget: budget_projection(budget.reload) }
      else
        render_refusal(result.outcome)
      end
    end

    def required_operation_key
      key = request.headers["Idempotency-Key"]
      return key if key.present?

      render_error(:idempotency_key_required, "Idempotency-Key header is required", status: :bad_request)
      nil
    end

    def budget_time(value, name)
      Time.zone.iso8601(value.to_s)
    rescue ArgumentError
      raise APIErrors::ParameterInvalid, name
    end

    def entry_projection(entry) = UsageBudgets::Projection.adjustment_entry(entry)
end
