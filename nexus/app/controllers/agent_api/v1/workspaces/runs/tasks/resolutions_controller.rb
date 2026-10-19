# Workspace-scoped and member-authenticated like every write here; the
# resolution token is a second factor checked inside the engine, never a
# credential of its own.
class AgentAPI::V1::Workspaces::Runs::Tasks::ResolutionsController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  include AgentAPI::V1::SettlementRendering

  def create
    run = find_listable_loop(@workspace)
    return unless authorize_writable(run)

    node = run.tasks
      .find_by!(node_key: params.fetch(:task_key), type: Tasks::AwaitTask.sti_name)

    fields = params.permit(:outcome, :resolution_token, :result_type)
    outcome = fields[:outcome]
    unless outcome.nil? || Runs::Parks::Settle::OUTCOMES.include?(outcome)
      return render_error(:invalid_outcome,
        %(outcome must be "completed" or "failed"), status: :unprocessable_entity)
    end

    # The await door takes the same MCP result grammar: `content` and
    # `structured_content` are opaque payloads read from the parsed body
    # verbatim. WHO ANSWERED: any principal with standing, the acting
    # user's KIND, id and handle (the name a person reads) on the
    # settle's own narration — the approval-origin precedent, no proxy
    # machinery; a child's relay says `conversation` there.
    envelope = request.request_parameters
    render_settlement(
      Runs::Parks::Settle.call(
        node: node, claim_token: fields[:resolution_token],
        answer: envelope["answer"], answer_present: envelope.key?("answer"),
        content: envelope["content"],
        structured_content: envelope["structured_content"],
        structured_content_present: envelope.key?("structured_content"),
        result_type: fields[:result_type], outcome: outcome,
        # A `resource_link` here names the answerer's own staged upload.
        creator: acting_user,
        resolved_by: { "kind" => acting_user.kind, "public_id" => acting_user.public_id, "handle" => acting_user.handle }
      ),
      node
    )
  end
end
