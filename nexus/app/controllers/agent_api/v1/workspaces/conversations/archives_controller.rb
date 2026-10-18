# The recycle bin's named verb, never an overload of update.
class AgentAPI::V1::Workspaces::Conversations::ArchivesController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def create
    lifecycle_command(::Conversations::Archive)
  end
end
