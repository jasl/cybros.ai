# The approver's refusal: `reason` is text or nothing — the detail the
# model reads back.
class AgentAPI::V1::Workspaces::AgentLoops::Tasks::DeniesController <
      AgentAPI::V1::Workspaces::AgentLoops::BaseController
  def create
    reason = params[:reason]
    raise APIErrors::ParameterInvalid, :reason unless reason.nil? || String.try_convert(reason)

    adjudicate(AgentLoops::Tasks::Deny, reason: reason)
  end
end
