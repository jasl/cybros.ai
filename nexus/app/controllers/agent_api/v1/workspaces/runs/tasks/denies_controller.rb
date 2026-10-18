# The approver's refusal: `reason` is text or nothing — the detail the
# model reads back.
class AgentAPI::V1::Workspaces::Runs::Tasks::DeniesController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  def create
    reason = params[:reason]
    raise APIErrors::ParameterInvalid, :reason unless reason.nil? || String.try_convert(reason)

    adjudicate(Runs::Tasks::Deny, reason: reason)
  end
end
