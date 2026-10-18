class API::V1::Agents::BaseController < API::V1::BaseController
  include AgentAPI::KeysetPagination

  before_action :load_agent

  private

    def agents
      Current.user.stewarded_agents.where(named_agent_scope: nil)
    end

    def load_agent
      @agent = agents.find_by!(public_id: params[:agent_id] || params[:id])
    end

    def render_agent_result(outcome)
      if %i[removed restored revoked].include?(outcome)
        render json: { agent: API::AgentPresenter.basic(@agent) }
      else
        render_refusal(outcome)
      end
    end
end
