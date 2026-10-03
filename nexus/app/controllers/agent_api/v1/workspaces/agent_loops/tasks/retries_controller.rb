class AgentAPI::V1::Workspaces::AgentLoops::Tasks::RetriesController <
      AgentAPI::V1::Workspaces::AgentLoops::BaseController
  def create
    model = params[:model]&.permit(:model, :reasoning_effort)&.to_h
    adjudicate(AgentLoops::Tasks::Retry, model: model)
  end
end
