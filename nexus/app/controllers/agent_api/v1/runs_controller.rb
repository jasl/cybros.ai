# @auth [MemberBearer]
class AgentAPI::V1::RunsController < AgentAPI::V1::Workspaces::BaseController
  include RunListing

  # @oas_include
  # @summary List runs
  # @tags Member, runs
  # @parameter after(query) [String] Opaque continuation cursor.
  # @parameter limit(query) [Integer] Page size; the resource reference specifies its bound.
  # @parameter order(query) [String] Ordering direction.
  # @response_ref (200) #/components/responses/AgentApiV1RunsIndex
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  def index
    scope = filtered_runs(Run.visible_to(acting_user, workspace: selected_workspace))
    page = keyset_page(scope, columns: { public_id: :uuid })
    render json: {
      runs: AgentAPI::RunPresenter.basic_many(page.records),
      pagination: { next_after: page.next_after },
    }
  end
end
