class AgentAPI::V1::WorkAnalysesController < AgentAPI::V1::Workspaces::BaseController
  include UsageAnalysisParameters

  def show
    window = report_window(unit: "day")
    raise APIErrors::ParameterInvalid, window.invalid_parameter if window.invalid_parameter

    result = ::WorkReports::Analysis.call(
      user: acting_user, workspace: selected_workspace, agent: selected_analysis_agent,
      from: window.from, to: window.to, filters: analysis_filters, **analysis_options
    )
    if result.outcome == :reported
      render json: { analysis: AgentAPI::WorkAnalysisPresenter.full(result.report) }
    else
      render_refusal(result.refusal)
    end
  end
end
