class AgentAPI::V1::Tools::BaseController < AgentAPI::V1::BaseController
  serves_plane :member

  before_action :require_agent_member

  private

    def require_agent_member
      render_refusal(:not_agent) unless current_credential.user.agent_member?
    end
end
