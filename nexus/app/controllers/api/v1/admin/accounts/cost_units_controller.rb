# The configure-once Account cost unit: a nil-only compare-and-set — a
# same-value replay is already configured, a different value is a conflict,
# and nothing rewrites a unit money was counted in.
class API::V1::Admin::Accounts::CostUnitsController < API::V1::Admin::BaseController
  def show
    render json: { account: { cost_unit: Current.user.account.cost_unit } }
  end

  def update
    fields = params.expect(account: [:cost_unit])
    result = Accounts::ConfigureCostUnit.call(
      account: Current.user.account, cost_unit: fields[:cost_unit]
    )

    case result.outcome
    when :configured, :already_configured
      render json: { account: { cost_unit: Current.user.account.reload.cost_unit } }
    when :conflict
      render_error(:cost_unit_conflict,
        "The account already counts in a different unit", status: :conflict)
    when :invalid
      raise APIErrors::ParameterInvalid, :cost_unit
    else
      raise "unmapped cost unit outcome: #{result.outcome}"
    end
  end
end
