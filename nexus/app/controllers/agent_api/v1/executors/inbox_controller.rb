# GET /agent_api/v1/executor/inbox — THIS credential's inbox: the truth half
# of the two channels. Every tool row the kernel addressed to this executor
# across every live loop, level-triggered and complete — the cable nudge
# carries no work of its own.
# @auth [ExecutorBearer]
class AgentAPI::V1::Executors::InboxController < AgentAPI::V1::Executors::BaseController
  # @oas_include
  # @summary Read inbox
  # @tags Executor, inbox
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ExecutorsInboxShow
  def show
    result = Executors::Inbox.call(
      executor: current_executor, after: cursor_param(Task::InboxCursor, :after),
      limit: limit_param(default: Executors::Inbox::DEFAULT_LIMIT, max: Executors::Inbox::MAX_LIMIT)
    )
    render json: { tasks: result.tasks, pagination: { next_after: result.next_after } }
  end
end
