# The workspace's store: one of three doors of the same family.
class AgentAPI::V1::Workspaces::StoreEntriesController < AgentAPI::V1::StoreEntriesController
  include AgentAPI::V1::WorkspaceScoped

  private

    def find_store_host = @workspace
end
