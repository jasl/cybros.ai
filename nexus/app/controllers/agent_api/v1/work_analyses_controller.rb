# @auth [MemberBearer]
class AgentAPI::V1::WorkAnalysesController < AgentAPI::V1::Workspaces::BaseController
  include UsageAnalysisParameters

  # @oas_include
  # @summary Read work analyses
  # @tags Member, work analyses
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkAnalysesShow
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
