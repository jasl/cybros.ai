module BudgetReading
  extend ActiveSupport::Concern
  include AgentAPI::KeysetPagination

  # @oas_include
  # @summary List budgets
  # @tags Platform, budgets
  # @parameter agent_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter user_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ConcernsBudgetReadingRbIndex
  def index
    target = budget_target
    measured_at = Time.current
    current = target.usage_budgets.usable_at(measured_at).includes(:account).first
    page = keyset_page(target.usage_budgets.includes(:account), columns: { starts_at: :timestamp, public_id: :uuid })
    render json: {
      user_public_id: target.public_id, user_kind: target.kind, cost_unit: target.account.cost_unit,
      measured_at: measured_at,
      current_budget: current && budget_projection(current, at: measured_at),
      budgets: page.records.map { |budget| budget_projection(budget, at: measured_at) },
      pagination: { next_after: page.next_after },
    }
  end

  # @oas_include
  # @summary Read budgets
  # @tags Platform, budgets
  # @parameter agent_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter user_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ConcernsBudgetReadingRbShow
  def show
    measured_at = Time.current
    render json: { budget: budget_projection(find_budget, at: measured_at), measured_at: measured_at }
  end

  private

    def find_budget
      budget_target.usage_budgets.includes(:account).find_by!(
        public_id: params[:budget_public_id] || params.fetch(:public_id)
      )
    end

    def budget_projection(budget, at: Time.current) = UsageBudgets::Projection.budget(budget, at: at)

    def render_budget_entries
      page = keyset_page(find_budget.entries, columns: { entry_sequence: :integer })
      render json: {
        entries: page.records.map { |entry| UsageBudgets::Projection.entry(entry) },
        pagination: { next_after: page.next_after },
      }
    end
end
