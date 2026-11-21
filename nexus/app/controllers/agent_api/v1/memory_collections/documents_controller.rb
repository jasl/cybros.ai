# @auth [MemberBearer]
class AgentAPI::V1::MemoryCollections::DocumentsController < AgentAPI::V1::MemoryCollections::BaseController
  include AgentAPI::MemoryOverrideGuard
  include AgentAPI::MemoryPreconditions

  # @oas_include
  # @summary List documents
  # @tags Member, documents
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
  # @response_ref (200) #/components/responses/AgentApiV1MemoryCollectionsDocumentsIndex
  def index
    return unless content_available?

    entries = MemoryDocuments::Listing.call(documents: collection.memory_documents, paths: ->(_id, name) { [name] })
    render json: { memory: AgentAPI::MemoryPresenter.listing(entries) }
  end

  # @oas_include
  # @summary Read documents
  # @tags Member, documents
  # @parameter memory_collection_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1MemoryCollectionsDocumentsShow
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1MemoryCollectionsDocumentsShow
  def show
    path = params.expect(memory: [:path])[:path]
    return unless content_available?(path)

    document = collection.memory_documents.eager_load(:memory_document_version).find_by(name: path)
    return render_refusal(:memory_not_found) unless document

    render json: { memory: AgentAPI::MemoryPresenter.full(document, path: path) }
  end

  # @oas_include
  # @summary Create documents
  # @tags Member, documents
  # @parameter memory_collection_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1MemoryCollectionsDocumentsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (201) #/components/responses/AgentApiV1MemoryCollectionsDocumentsCreate
  def create
    fields = params.expect(memory: [:path, :content, :description, :expected_public_id, :expected_lock_version])
    return unless content_available?(fields[:path])

    expected = memory_precondition(fields, allow_absent: true)
    result = document_commands.apply(fields[:path]) do |anchor|
      MemoryDocuments::Write.call(anchor: anchor, content: fields[:content], description: fields[:description], expected: expected)
    end
    render_document(result, fields[:path], status: :created)
  end

  # @oas_include
  # @summary Delete documents
  # @tags Member, documents
  # @parameter memory_collection_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1MemoryCollectionsDocumentsDelete
  # @response_ref (204) #/components/responses/AgentApiV1MemoryCollectionsDocumentsDelete
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  def delete
    fields = params.expect(memory: [:path, :expected_public_id, :expected_lock_version])
    return unless content_available?(fields[:path])

    expected = memory_precondition(fields, allow_absent: false)
    result = document_commands.apply(fields[:path]) { |anchor| MemoryDocuments::Delete.call(anchor: anchor, expected: expected) }
    result.outcome == :deleted ? head(:no_content) : render_refusal(result.outcome)
  end

  private

    def document_commands = ::MemoryCollections::Documents.new(collection: collection, by: acting_user)

    def content_available?(path = nil)
      workspace = collection.workspace || collection.conversation&.workspace
      workspace.nil? || not_overridden(workspace, path: ("#{collection.natural_scope}/#{path}" if path))
    end

    def render_document(result, path, status: :ok)
      if result.written?
        render json: { memory: AgentAPI::MemoryPresenter.full(result.document, path: path) }, status: status
      else
        render_refusal(result.outcome)
      end
    end
end
