class AgentAPI::V1::Workspaces::MemoryCollectionsController < AgentAPI::V1::MemoryCollections::OwnedController
  include AgentAPI::V1::WorkspaceScoped

  private

    def owner = @workspace
    def owner_scope = :workspace
end
