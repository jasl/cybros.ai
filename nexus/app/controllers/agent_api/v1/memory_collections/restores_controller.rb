# @auth [MemberBearer]
class AgentAPI::V1::MemoryCollections::RestoresController < AgentAPI::V1::MemoryCollections::BaseController
  # @oas_include
  # @summary Create restores
  # @tags Member, restores
  # @parameter memory_collection_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1MemoryCollectionsRestoresCreate
  def create = lifecycle(:restore)
end
