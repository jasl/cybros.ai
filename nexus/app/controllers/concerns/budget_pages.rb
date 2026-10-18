module BudgetPages
  extend ActiveSupport::Concern
  include APIErrors
  include AgentAPI::KeysetPagination

  included do
    before_action :prepare_budget_page
    helper_method :budget_collection_path, :budget_detail_path, :budget_new_path,
      :budget_edit_path, :budget_revocation_path
  end

  def index
    current = @budget_target.usage_budgets.usable_at(@measured_at).includes(:account).first
    @current_budget = current && UsageBudgets::Projection.budget(current, at: @measured_at)
    @page = keyset_page(@budget_target.usage_budgets.includes(:account), columns: { starts_at: :timestamp, public_id: :uuid })
    @budgets = @page.records.map { |budget| UsageBudgets::Projection.budget(budget, at: @measured_at) }
    render "budgets/index"
  end

  def show
    prepare_budget_detail
    render "budgets/show"
  end

  def new
    @draft = { "operation_key" => SecureRandom.uuid_v7, "starts_at" => Time.current.utc.iso8601, "amount" => "" }
    render "budgets/new"
  end

  def create
    @draft = params.expect(budget: [:amount, :starts_at, :expires_at, :reason, :operation_key]).to_h
    @error_template = "budgets/new"
    result = UsageBudgets::Open.call(
      actor: Current.user, target: @budget_target, amount: @draft["amount"],
      starts_at: form_budget_time(@draft["starts_at"], :starts_at),
      expires_at: @draft["expires_at"].blank? ? nil : form_budget_time(@draft["expires_at"], :expires_at),
      operation_key: @draft["operation_key"], reason: @draft["reason"]
    )
    if result.opened?
      redirect_to budget_detail_path(result.budget.public_id), notice: t("budget_console.opened"), status: :see_other
    else
      render_budget_refusal(result.outcome)
    end
  end

  def edit
    @budget = UsageBudgets::Projection.budget(find_budget, at: @measured_at)
    @draft = { "operation_key" => SecureRandom.uuid_v7, "kind" => "credit", "amount" => "" }
    render "budgets/edit"
  end

  def update
    budget = find_budget
    @budget = UsageBudgets::Projection.budget(budget, at: @measured_at)
    @draft = params.expect(budget: [:kind, :amount, :reason, :operation_key]).to_h
    @error_template = "budgets/edit"
    result = UsageBudgets::Adjust.call(
      actor: Current.user, budget: budget, kind: @draft["kind"].to_s.to_sym,
      amount: @draft["amount"], operation_key: @draft["operation_key"], reason: @draft["reason"]
    )
    if result.adjusted?
      redirect_to budget_detail_path(budget.public_id), notice: t("budget_console.adjusted"), status: :see_other
    else
      render_budget_refusal(result.outcome)
    end
  end

  private

    def prepare_budget_page
      @budget_target = budget_target
      @measured_at = Time.current
      @budget_personal = personal_budget?
      @budget_back_path = budget_back_path
    end

    def personal_budget? = false

    def find_budget
      @budget_target.usage_budgets.includes(:account).find_by!(public_id: params[:budget_public_id] || params.fetch(:public_id))
    end

    def prepare_budget_detail
      budget = find_budget
      @budget = UsageBudgets::Projection.budget(budget, at: @measured_at)
      @page = keyset_page(budget.entries, columns: { entry_sequence: :integer })
      @entries = @page.records.map { |entry| UsageBudgets::Projection.entry(entry) }
      @revocation_draft ||= { "operation_key" => SecureRandom.uuid_v7, "reason" => "" }
    end

    def revoke_budget
      @revocation_draft = params.expect(revocation: [:reason, :operation_key]).to_h
      budget = find_budget
      @error_template = "budgets/show"
      result = UsageBudgets::Revoke.call(actor: Current.user, budget: budget,
        operation_key: @revocation_draft["operation_key"], reason: @revocation_draft["reason"])
      if result.revoked?
        redirect_to budget_detail_path(budget.public_id), notice: t("budget_console.revoked"), status: :see_other
      else
        @revocation_refused = true
        prepare_budget_detail
        render_budget_refusal(result.outcome)
      end
    end

    def form_budget_time(value, name)
      Time.find_zone!("UTC").iso8601(value.to_s)
    rescue ArgumentError
      raise APIErrors::ParameterInvalid, name
    end

    def render_budget_refusal(outcome)
      code = BudgetWriting::REFUSAL_CODES.fetch(outcome, outcome)
      status = BudgetWriting::REFUSAL_STATUSES.fetch(code, BudgetWriting::REFUSAL_DEFAULT_STATUS)
      render_error(code, t("budget_console.errors.#{outcome}"), status: status)
    end

    def render_error(code, message, status:)
      @error = message
      render @error_template || "budgets/error", status: Nexus::FamilyErrors.status_for(code) || status
    end

    def budget_collection_path(**options) = url_for(budget_route_parameters.merge(action: :index, public_id: nil, budget_public_id: nil, only_path: true, **options))
    def budget_detail_path(public_id, **options) = url_for(budget_route_parameters.merge(action: :show, public_id: public_id, only_path: true, **options))
    def budget_new_path = url_for(budget_route_parameters.merge(action: :new, only_path: true))
    def budget_edit_path(public_id) = url_for(budget_route_parameters.merge(action: :edit, public_id: public_id, only_path: true))

    def budget_revocation_path(public_id)
      url_for(budget_route_parameters.merge(controller: "#{budget_route_parameters.fetch(:controller)}/revocations",
        action: :create, budget_public_id: public_id, only_path: true))
    end
end
