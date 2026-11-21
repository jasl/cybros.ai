# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::Memory::EditsController <
      AgentAPI::V1::Workspaces::Conversations::MemoryController
  # @oas_include
  # @summary Create edits
  # @tags Member, edits
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesConversationsMemoryEditsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsMemoryEditsCreate
  def create
    fields = params.expect(memory: [:path, :old_text, :new_text, :expected_collection_public_id, :expected_public_id, :expected_lock_version, :speaker_public_id])
    return unless not_overridden(@workspace, path: fields[:path])

    conversation = find_listable_conversation(@workspace)
    return unless authorize_writable(conversation)

    expected = memory_precondition(fields, allow_absent: false)
    result = ::Conversations::Memory::Apply.edit(conversation: conversation, path: fields[:path],
      old_text: fields[:old_text], new_text: fields[:new_text], by: acting_user, expected: expected, speaker: @memory_speaker,
      expected_collection_public_id: memory_collection_precondition(fields))
    return render_refusal(result.outcome) unless result.accepted?

    render json: { memory: AgentAPI::MemoryPresenter.full(result.value, path: fields[:path]) }
  end
end
