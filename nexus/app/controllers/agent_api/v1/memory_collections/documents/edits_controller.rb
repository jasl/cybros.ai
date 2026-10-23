class AgentAPI::V1::MemoryCollections::Documents::EditsController < AgentAPI::V1::MemoryCollections::DocumentsController
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
