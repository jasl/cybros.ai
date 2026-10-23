class AgentAPI::V1::MemoryCollections::RestoresController < AgentAPI::V1::MemoryCollections::BaseController
  def create = lifecycle(:restore)
end
