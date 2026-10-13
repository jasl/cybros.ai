# The principal's own store: the ACTING user's row — an agent's is the
# agent's, not its steward's — so the host can never miss.
class AgentAPI::V1::Profiles::StoreEntriesController < AgentAPI::V1::StoreEntriesController
  private

    def find_store_host = acting_user
end
