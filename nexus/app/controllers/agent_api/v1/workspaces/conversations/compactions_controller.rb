# Compact now, because somebody asked: the kernel still picks no threshold,
# and a caller who can see a conversation getting expensive can say so.
class AgentAPI::V1::Workspaces::Conversations::CompactionsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def create
    conversation = find_listable_conversation(@workspace)

    result = ::Conversations::Compaction::Request.call(
      ::Conversations::Compaction::Request::Command.new(
        conversation: conversation,
        acting_user: acting_user,
        model: compaction_params[:model],
        reasoning_effort: compaction_params[:reasoning_effort]
      )
    )

    return render_accepted(result) if result.accepted?

    render_refusal(result.outcome)
  end

  private

    def compaction_params
      params.fetch(:compaction, ActionController::Parameters.new)
        .permit(:model, :reasoning_effort)
    end

    # The turn on either host; mid-turn also the round repaired and the
    # summarizer's key, read by presence.
    def render_accepted(result)
      compacted = result.value
      turn = compacted.turn
      task = compacted.task
      render json: {
        turn: { public_id: turn.public_id, position: turn.position,
                kind: turn.kind, status: turn.status },
        task: (task && { key: task.node_key,
                         status: AgentAPI::AgentLoopPresenter.public_status(task.reload.status) }),
        summary_task_key: compacted.summary_task_key,
      }.compact, status: :accepted
    end
end
