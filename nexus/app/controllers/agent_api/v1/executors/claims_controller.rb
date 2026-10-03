# POST grants a claim; GET reads that exact execution without granting work.
# Two processes of one address both see a parked
# row; exactly one may execute it. The minted token is the commit door's
# key and rotates on every claim, so a runner back from the dead cannot
# settle over the current holder. One clock, no heartbeat. A POST refusal is
# a reachable conflict — including the loop's principal losing standing,
# a fact about the ROW's loop and not this credential's authorization.
class AgentAPI::V1::Executors::ClaimsController < AgentAPI::V1::Executors::BaseController
  CLAIM_READ_RATE_LIMIT = 600

  prepend_before_action :no_store, only: :show

  def show
    # The claim read carries its proof only in this header (executor.md,
    # "Read an existing claim"), never in a URL or the response.
    token = request.headers["Claim-Token"]
    raise ActionController::ParameterMissing.new("Claim-Token") if token.blank?

    agent_loop = find_addressable_loop
    return render_not_found if agent_loop.tombstoned?

    node = agent_loop.agent_loop_nodes.find_by!(node_key: params.fetch(:task_key), type: AgentLoopNodes::PARKED_TYPES)
    unless node.claimed_by?(current_executor, token: token)
      return render_error(:not_claimant, "Refused: not_claimant", status: :conflict)
    end

    render json: { claim: { active: node.status == "dispatched" } }
  end

  def create
    agent_loop = find_addressable_loop
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: params.fetch(:task_key), executor: current_executor
    ))

    case result.outcome
    when :accepted
      # The executable row the inbox lists, not the trace projection:
      # claiming is the fetch, so no runner pages the inbox for the arguments.
      node = result.value.reload
      render json: {
        task: Executors::Inbox.row(node),
        claim: { claim_token: node.claim_token, deadline_at: node.deadline_at },
      }
    when :not_found
      render_error(:not_found, "Not found", status: :not_found)
    else
      render_error(result.outcome.to_s, "Refused: #{result.outcome}", status: :conflict)
    end
  end

  private

    def caller_rate_limit
      action_name == "show" ? CLAIM_READ_RATE_LIMIT : super
    end

    def rate_limit_identity = "#{super}/#{action_name}"
end
