# The conversation's own store: the client state that forks with it; the
# archived bin stays browsable, a tombstone reads as absence.
class AgentAPI::V1::Workspaces::Conversations::StoreEntriesController <
      AgentAPI::V1::StoreEntriesController
  include AgentAPI::V1::WorkspaceScoped

  private

    def find_store_host
      find_listable_conversation(@workspace)
    end
end
