# @auth [MemberBearer]
class AgentAPI::V1::MemoryCollections::Documents::EditsController < AgentAPI::V1::MemoryCollections::DocumentsController
  # @oas_include
  # @summary Create edits
  # @tags Member, edits
  # @parameter memory_collection_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1MemoryCollectionsDocumentsEditsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1MemoryCollectionsDocumentsEditsCreate
  def create
    fields = params.expect(memory: [:path, :old_text, :new_text, :expected_public_id, :expected_lock_version])
    return unless content_available?(fields[:path])

    expected = memory_precondition(fields, allow_absent: false)
    result = document_commands.apply(fields[:path]) do |anchor|
      MemoryDocuments::Edit.call(anchor: anchor, old_text: fields[:old_text], new_text: fields[:new_text], expected: expected)
    end
    render_document(result, fields[:path])
  end
end
