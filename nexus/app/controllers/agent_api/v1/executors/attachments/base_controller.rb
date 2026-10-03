# The active claim reads its loop's input files without a member credential,
# signed blob URL, or another upload store. Authorization precedes streaming.
class AgentAPI::V1::Executors::Attachments::BaseController < AgentAPI::V1::Executors::BaseController
  prepend_before_action :no_store
  before_action :require_active_claim

  private

    def require_active_claim
      token = request.headers["Claim-Token"]
      raise ActionController::ParameterMissing.new("Claim-Token") if token.blank?

      @agent_loop = find_addressable_loop
      return render_not_found if @agent_loop.tombstoned?

      node = @agent_loop.agent_loop_nodes.find_by!(node_key: params.fetch(:task_key), type: AgentLoopNodes::PARKED_TYPES)
      unless node.claimed_by?(current_executor, token: token)
        return render_error(:not_claimant, "Refused: not_claimant", status: :conflict)
      end
      unless node.status == "dispatched" && !node.deadline_passed?
        render_error(:claim_inactive, "Refused: claim_inactive", status: :conflict)
      end
    end

    def attachment(public_id)
      Executors::Attachments.fetch(agent_loop: @agent_loop, public_id: public_id)
    end
end
