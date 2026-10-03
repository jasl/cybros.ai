# POST /agent_api/v1/executor/inbox/{loop}/{task_key}/commit — the executor
# plane's commit: the answer settles against the token its claim minted,
# with the two-axis law — `is_error: true` on a completed outcome is a tool
# that ran and errored (data the continuation reads); `outcome: "failed"`
# could not run and takes on_failure. Write-once: a second commit under the
# same token after the settle is `idle`.
class AgentAPI::V1::Executors::CommitsController < AgentAPI::V1::Executors::BaseController
  include AgentAPI::V1::SettlementRendering

  def create
    agent_loop = find_addressable_loop
    fields = params.permit(:outcome, :claim_token, :result_type, :title, :is_error)
    outcome = fields[:outcome] || "completed"
    unless AgentLoops::Parks::Settle::OUTCOMES.include?(outcome)
      return render_error(:invalid_outcome,
        %(outcome must be "completed" or "failed"), status: :unprocessable_entity)
    end

    # The MCP result grammar: `content`, `structured_content` and `metadata`
    # are opaque payloads read from the parsed body verbatim, never through a
    # permit that drops non-text blocks.
    envelope = request.request_parameters
    result = Executors::Commit.call(Executors::Commit::Command.new(
      agent_loop: agent_loop, task_key: params.fetch(:task_key), executor: current_executor,
      claim_token: fields[:claim_token], content: envelope["content"],
      structured_content: envelope["structured_content"], result_type: fields[:result_type],
      outcome: outcome, is_error: fields[:is_error] == true,
      title: fields[:title], metadata: Hash.try_convert(envelope["metadata"])
    ))
    render_settlement(result, result.node)
  end
end
