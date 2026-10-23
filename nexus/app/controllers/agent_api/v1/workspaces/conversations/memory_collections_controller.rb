class AgentAPI::V1::Workspaces::Conversations::MemoryCollectionsController < AgentAPI::V1::MemoryCollections::OwnedController
  include AgentAPI::V1::WorkspaceScoped

  private

    def owner = @owner ||= find_listable_conversation(@workspace)
    def owner_scope = :conversation
end
