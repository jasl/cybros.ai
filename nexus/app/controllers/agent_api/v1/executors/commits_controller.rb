# POST /agent_api/v1/executor/inbox/{loop}/{task_key}/commit — the executor
# plane's commit: the answer settles against the token its claim minted,
# with the two-axis law — `is_error: true` on a completed outcome is a tool
# that ran and errored (data the continuation reads); `outcome: "failed"`
# could not run and takes on_failure. Write-once: a second commit under the
# same token after the settle is `idle`.
# @auth [ExecutorBearer]
class AgentAPI::V1::Executors::CommitsController < AgentAPI::V1::Executors::BaseController
  include AgentAPI::V1::SettlementRendering

  # @oas_include
  # @summary Create commits
  # @tags Executor, commits
  # @parameter run_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter task_key(path) [!String] Resource selector.
  # @request_body_ref #/components/requestBodies/AgentApiV1ExecutorsCommitsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ExecutorsCommitsCreate
  def create
    run = find_addressable_loop
    fields = params.permit(:outcome, :claim_token, :result_type, :title, :is_error)
    outcome = fields[:outcome] || "completed"
    unless Runs::Parks::Settle::OUTCOMES.include?(outcome)
      return render_error(:invalid_outcome,
        %(outcome must be "completed" or "failed"), status: :unprocessable_entity)
    end

    # The MCP result grammar: `content`, `structured_content` and `metadata`
    # are opaque payloads read from the parsed body verbatim, never through a
    # permit that drops non-text blocks.
    envelope = request.request_parameters
    result = Executors::Commit.call(Executors::Commit::Command.new(
      run: run, task_key: params.fetch(:task_key), executor: current_executor,
      claim_token: fields[:claim_token], content: envelope["content"],
      structured_content: envelope["structured_content"], result_type: fields[:result_type],
      structured_content_present: envelope.key?("structured_content"),
      outcome: outcome, is_error: fields[:is_error] == true,
      title: fields[:title], metadata: Hash.try_convert(envelope["metadata"])
    ))
    render_settlement(result, result.node)
  end
end
