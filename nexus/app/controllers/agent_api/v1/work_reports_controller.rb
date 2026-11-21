# @auth [MemberBearer]
class AgentAPI::V1::WorkReportsController < AgentAPI::V1::Workspaces::BaseController
  include ReportWindowParameters

  # @oas_include
  # @summary Read work reports
  # @tags Member, work reports
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkReportsShow
  def show
    window = report_window
    raise APIErrors::ParameterInvalid, window.invalid_parameter if window.invalid_parameter

    workspace = selected_workspace
    agent = current_account.users.where(kind: :agent).find_by!(public_id: params.expect(:agent_public_id).to_s) if params[:agent_public_id].present?
    result = ::WorkReports::Report.call(
      user: acting_user, workspace:, agent:, from: window.from, to: window.to, unit: window.unit
    )
    if result.outcome == :reported
      render json: { report: AgentAPI::WorkReportPresenter.full(result.report) }
    else
      render_refusal(result.refusal)
    end
  end
end
