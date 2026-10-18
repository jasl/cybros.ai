class API::V1::Admin::ModelUsageAnalysesController < API::V1::Admin::BaseController
  include UsageAnalysisParameters

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
