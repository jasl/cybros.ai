# The approver's refusal: `reason` is text or nothing — the detail the
# model reads back.
class AgentAPI::V1::Workspaces::AgentRuns::Tasks::DeniesController <
      AgentAPI::V1::Workspaces::AgentRuns::BaseController
  def create
    reason = params[:reason]
    raise APIErrors::ParameterInvalid, :reason unless reason.nil? || String.try_convert(reason)

    adjudicate(AgentRuns::Tasks::Deny, reason: reason)
  end
end
