# GET /agent_api/v1/executor/inbox — THIS credential's inbox: the truth half
# of the two channels. Every tool row the kernel addressed to this executor
# across every live loop, level-triggered and complete — the cable nudge
# carries no work of its own.
class AgentAPI::V1::Executors::InboxController < AgentAPI::V1::Executors::BaseController
  def show
    result = Executors::Inbox.call(
      executor: current_executor, after: cursor_param(AgentRunTask::InboxCursor, :after),
      limit: limit_param(default: Executors::Inbox::DEFAULT_LIMIT, max: Executors::Inbox::MAX_LIMIT)
    )
    render json: { tasks: result.tasks, pagination: { next_after: result.next_after } }
  end
end
