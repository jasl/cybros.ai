class AgentAPI::V1::MemoryCollections::ArchivesController < AgentAPI::V1::MemoryCollections::BaseController
  def create = lifecycle(:archive)
end
