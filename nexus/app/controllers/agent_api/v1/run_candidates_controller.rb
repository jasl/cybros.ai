# @auth [MemberBearer]
class AgentAPI::V1::RunCandidatesController < AgentAPI::V1::Workspaces::BaseController
  # @oas_include
  # @summary List run candidates
  # @tags Member, run candidates
  # @parameter after(query) [String] Opaque continuation cursor.
  # @parameter limit(query) [Integer] Page size; the resource reference specifies its bound.
  # @parameter order(query) [String] Ordering direction.
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1RunCandidatesIndex
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
