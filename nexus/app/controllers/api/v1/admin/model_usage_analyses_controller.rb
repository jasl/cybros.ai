# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::ModelUsageAnalysesController < API::V1::Admin::BaseController
  include UsageAnalysisParameters

  # @oas_include
  # @summary Read model usage analyses
  # @tags Platform, model usage analyses
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminModelUsageAnalysesShow
  def show
    window = report_window(unit: "day")
    raise APIErrors::ParameterInvalid, window.invalid_parameter if window.invalid_parameter

    result = ModelUsageRollups::Analysis.call(
      account: Current.account, from: window.from, to: window.to,
      filters: admin_analysis_filters, **analysis_options
    )
    if result.outcome == :reported
      render json: { analysis: ModelUsageAnalysisPresenter.full(result.report) }
    else
      render_refusal(result.refusal)
    end
  end
end
