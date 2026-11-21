# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::Memory::GrepsController <
      AgentAPI::V1::Workspaces::Conversations::MemoryController
  # @oas_include
  # @summary Create greps
  # @tags Member, greps
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesConversationsMemoryGrepsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsMemoryGrepsCreate
  def create
    fields = params.expect(memory: [:pattern, :path, :ignore_case, :limit, :speaker_public_id])
    return unless not_overridden(@workspace, path: fields[:path])

    conversation = find_listable_conversation(@workspace)
    result = memory_context(conversation).search(pattern: fields[:pattern], path: fields[:path],
      ignore_case: ActiveModel::Type::Boolean.new.cast(fields[:ignore_case]),
      limit: limit_param(value: fields[:limit], default: MemoryDocuments::Search::DEFAULT_LIMIT,
        max: MemoryDocuments::Search::MAX_LIMIT))
    return render_refusal(result.refusal) unless result.found?

    render json: AgentAPI::MemoryPresenter.search(result)
  end
end
