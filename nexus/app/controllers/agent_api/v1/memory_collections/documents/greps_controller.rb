# @auth [MemberBearer]
class AgentAPI::V1::MemoryCollections::Documents::GrepsController < AgentAPI::V1::MemoryCollections::DocumentsController
  # @oas_include
  # @summary Create greps
  # @tags Member, greps
  # @parameter memory_collection_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1MemoryCollectionsDocumentsGrepsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1MemoryCollectionsDocumentsGrepsCreate
  def create
    fields = params.expect(memory: [:pattern, :path, :ignore_case, :limit])
    return unless content_available?(fields[:path])

    result = MemoryDocuments::Search.call(documents: collection.memory_documents, pattern: fields[:pattern], path_prefix: fields[:path],
      ignore_case: ActiveModel::Type::Boolean.new.cast(fields[:ignore_case]),
      limit: limit_param(value: fields[:limit], default: MemoryDocuments::Search::DEFAULT_LIMIT, max: MemoryDocuments::Search::MAX_LIMIT),
      paths: ->(document) { [document.name] })
    result.found? ? render(json: AgentAPI::MemoryPresenter.search(result)) : render_refusal(result.refusal)
  end
end
