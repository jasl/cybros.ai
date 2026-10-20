class AgentAPI::V1::RunCandidatesController < AgentAPI::V1::Workspaces::BaseController
  def index
    agent_public_id = params[:agent_public_id].presence || acting_user.public_id
    agent_public_id = String.try_convert(agent_public_id)
    raise APIErrors::ParameterInvalid, :agent_public_id unless agent_public_id && Nexus::ToolRoute::UUID.match?(agent_public_id)
    raise APIErrors::ParameterInvalid, :after if params[:after] && !String.try_convert(params[:after])

    page = Runs::Candidates.new(user: acting_user, agent_public_id: agent_public_id.downcase, after: params[:after]).call
    render json: { runs: page.runs.map(&:to_h), pagination: { next_after: page.next_after } }
  rescue Runs::Candidates::InvalidCursor
    raise APIErrors::ParameterInvalid, :after
  end
end
