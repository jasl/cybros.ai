# POST /agent_api/v1/executor/inbox/{loop}/{task_key}/extend — the claimant's
# extension, between the claim and the commit on the executor plane:
# `{claim_token, timeout_ms}` moves the one clock by at most the tool's
# announced park or the kernel's hour, and answers the same `{task, claim}` a
# grant does, deadline moved. Every refusal is a reachable conflict under one
# code — `not_extendable` (not a claimed dispatched park on an answerable
# loop), `not_claimant` (the address or the token is not the current
# claimant's), `extension_too_long` — and a malformed extension is
# unprocessable before any lock is taken.
class AgentAPI::V1::Executors::ExtendsController < AgentAPI::V1::Executors::BaseController
  # The door's own conflicts, published by the contract pack; `not_claimant`
  # is the claim-keyed word the progress door shares.
  CONFLICTS = %i[not_extendable not_claimant extension_too_long].freeze

  def create
    agent_run = find_addressable_loop
    timeout_ms = Integer(params[:timeout_ms], exception: false)
    unless timeout_ms&.positive?
      return render_error(:invalid_timeout_ms, "timeout_ms must be a positive integer of milliseconds",
        status: :unprocessable_entity)
    end

    result = Executors::Extend.call(Executors::Extend::Command.new(
      agent_run: agent_run, task_key: params.fetch(:task_key), executor: current_executor,
      claim_token: params[:claim_token], timeout_ms: timeout_ms
    ))

    case result.outcome
    when :accepted
      node = result.value.reload
      render json: {
        task: Executors::Inbox.row(node),
        claim: { claim_token: node.claim_token, deadline_at: node.wall_deadline_at },
      }
    when :not_found
      render_error(:not_found, "Not found", status: :not_found)
    when *CONFLICTS
      render_error(result.outcome.to_s, "Refused: #{result.outcome}", status: :conflict)
    else
      raise "unmapped extension outcome: #{result.outcome}"
    end
  end
end
