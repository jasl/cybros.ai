# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::MessagingController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Read messaging
  # @tags Member, messaging
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesMessagingShow
  def show
    render json: { messaging: AgentAPI::WorkspaceMessagingPresenter.full(@workspace) }
  end

  # @oas_include
  # @summary Update messaging
  # @tags Member, messaging
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesMessagingUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesMessagingUpdate
  def update
    fields = params.expect(messaging: [
      :lock_version,
      { agents: [[:agent_public_id, :mode, { allowed_sender_public_ids: [] }]] },
    ])
    # Empty explicitly clears the policy; omission must not silently widen it.
    raise ActionController::ParameterMissing.new(:agents) unless fields.key?(:agents)

    result = ::Workspaces::UpdateMessaging.call(
      workspace: @workspace,
      by: acting_user,
      agents: fields.fetch(:agents).map(&:to_h),
      lock_version: lock_version_from(fields),
    )

    if result.outcome == :updated
      render json: { messaging: AgentAPI::WorkspaceMessagingPresenter.full(result.workspace) }
    else
      render_refused(result)
    end
  end
end
