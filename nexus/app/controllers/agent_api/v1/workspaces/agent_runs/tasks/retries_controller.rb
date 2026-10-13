class AgentAPI::V1::Workspaces::AgentRuns::Tasks::RetriesController <
      AgentAPI::V1::Workspaces::AgentRuns::BaseController
  def create
    model = params[:model]&.permit(:model, :reasoning_effort, :reasoning_enabled)&.to_h
    model["reasoning_enabled"] = cast_boolean(model["reasoning_enabled"]) if model&.key?("reasoning_enabled")
    adjudicate(AgentRuns::Tasks::Retry, model: model)
  end
end
