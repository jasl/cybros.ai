class AgentAPI::V1::Workspaces::Conversations::UnarchivesController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def create
    lifecycle_command(::Conversations::Unarchive)
  end
end
