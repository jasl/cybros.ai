# The configure-once Account cost unit: a nil-only compare-and-set — a
# same-value replay is already configured, a different value is a conflict,
# and nothing rewrites a unit money was counted in.
# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::Accounts::CostUnitsController < API::V1::Admin::BaseController
  # @oas_include
  # @summary Read cost units
  # @tags Platform, cost units
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminAccountsCostUnitsShow
  def show
    render json: { account: { cost_unit: Current.user.account.cost_unit } }
  end

  # @oas_include
  # @summary Update cost units
  # @tags Platform, cost units
  # @request_body_ref #/components/requestBodies/ApiV1AdminAccountsCostUnitsUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminAccountsCostUnitsUpdate
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
