class AgentAPI::V1::Workspaces::MessagingController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def show
    render json: { messaging: AgentAPI::WorkspaceMessagingPresenter.full(@workspace) }
  end

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
