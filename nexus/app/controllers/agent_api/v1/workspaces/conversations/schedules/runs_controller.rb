# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::Schedules::RunsController <
      AgentAPI::V1::Workspaces::Conversations::Schedules::BaseController
  # @oas_include
  # @summary Create runs
  # @tags Member, runs
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter schedule_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsSchedulesRunsCreate
  def create = render_schedule(::Schedules::Manage.run_now(find_schedule, by: acting_user))
end
