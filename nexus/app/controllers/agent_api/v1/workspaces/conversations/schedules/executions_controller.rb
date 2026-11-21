# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::Schedules::ExecutionsController <
      AgentAPI::V1::Workspaces::Conversations::Schedules::BaseController
  # @oas_include
  # @summary List executions
  # @tags Member, executions
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter schedule_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter after(query) [String] Opaque continuation cursor.
  # @parameter limit(query) [Integer] Page size; the resource reference specifies its bound.
  # @parameter order(query) [String] Ordering direction.
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsSchedulesExecutionsIndex
  def index
    job = find_schedule
    scope = Conversation.visible_to(acting_user, workspace: @workspace).where(schedule_id: job.id)
    page = keyset_page(scope, columns: { public_id: :uuid })
    projected = ::Schedules::ExecutionProjection.call(page.records.map(&:id))
    last_cursor = page.records.last && encode_cursor(page.records.last, [:public_id], list_direction)
    render json: { executions: page.records.map { |child| projected.fetch(child.id) },
      pagination: { next_after: page.next_after, last_cursor: last_cursor || params[:after] } }
  end
end
