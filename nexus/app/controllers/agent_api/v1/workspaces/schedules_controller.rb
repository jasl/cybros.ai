# The workspace's scheduled jobs across its conversations: the overview a
# person reads before opening a job's own conversation. Rows reach the
# caller through the one conversation funnel the nested list uses, so a
# conversation the caller cannot read contributes nothing.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::SchedulesController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include ScheduleListing

  # @oas_include
  # @summary List schedules
  # @tags Member, schedules
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesSchedulesIndex
  def index
    scope = filtered_schedules(Schedule.visible_to(acting_user, workspace: @workspace)).including_context
    page = keyset_page(scope, columns: { public_id: :uuid })
    render json: { schedules: ::Schedules::Projection.many(page.records, by: acting_user, workspace: @workspace),
      pagination: { next_after: page.next_after } }
  end
end
