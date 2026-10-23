class AgentAPI::V1::MemoryCollections::BaseController < AgentAPI::V1::MemoryCollectionsController
  private

    def collection = @collection ||= collections.find_by!(public_id: params.fetch(:memory_collection_public_id))
end
