# The conversation plane's only memory writer: a `direct_reply` has no tools,
# so memory reaches its model through the assembly block via here. Paths ride
# in the body — `workspace/notes.md` survives no routing convention. The
# effective bindings select roots; Speaker memory requires an explicit
# subject here because management never guesses from a previous input.
# WHILE THE WORKSPACE IS OVERRIDDEN the whole door refuses
# `memory_overridden` (409, naming the provider) for reads and writes — the
# `user/` rung included, which the person's own collection resource keeps
# serving. `MemoryOverrideGuard` also protects Workspace/Conversation-owned
# collection document resources; a collection UUID cannot bypass the override.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::MemoryController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include AgentAPI::MemoryOverrideGuard
  include AgentAPI::MemoryPreconditions
  include AgentAPI::SpeakerParameters
  before_action :resolve_memory_speaker

  # @oas_include
  # @summary List memory
  # @tags Member, memory
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsMemoryIndex
  def index
    return unless not_overridden(@workspace)

    conversation = find_listable_conversation(@workspace)

    context = memory_context(conversation)
    render json: { memory: AgentAPI::MemoryPresenter.listing(context.listing), memory_context: context.management_projection }
  end

  # @oas_include
  # @summary Read memory
  # @tags Member, memory
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesConversationsMemoryShow
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsMemoryShow
  def show
    return unless not_overridden(@workspace, path: path_param)

    conversation = find_listable_conversation(@workspace)
    anchor = resolve(conversation)
    return if performed?

    document = anchor.documents.eager_load(:memory_document_version).find_by(name: anchor.name)
    return render_refusal(:memory_not_found) if document.nil?

    render json: { memory: AgentAPI::MemoryPresenter.full(document).merge(path: path_param) }
  end

  # @oas_include
  # @summary Create memory
  # @tags Member, memory
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesConversationsMemoryCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (201) #/components/responses/AgentApiV1WorkspacesConversationsMemoryCreate
  def create
    fields = params.expect(memory: [:path, :content, :description, :expected_collection_public_id, :expected_public_id, :expected_lock_version, :speaker_public_id])
    return unless not_overridden(@workspace, path: fields[:path])

    conversation = find_listable_conversation(@workspace)
    return unless authorize_writable(conversation)

    expected = memory_precondition(fields, allow_absent: true)
    result = ::Conversations::Memory::Apply.write(
      conversation: conversation, path: fields[:path], content: fields[:content],
      by: acting_user, expected: expected, description: fields[:description], speaker: @memory_speaker,
      expected_collection_public_id: memory_collection_precondition(fields)
    )
    return render_refusal(result.outcome) unless result.accepted?

    render json: { memory: AgentAPI::MemoryPresenter.full(result.value).merge(path: fields[:path]) },
      status: :created
  end

  # @oas_include
  # @summary Delete memory
  # @tags Member, memory
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesConversationsMemoryDelete
  # @response_ref (204) #/components/responses/AgentApiV1WorkspacesConversationsMemoryDelete
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
    fields = params.expect(memory: [:path, :expected_collection_public_id, :expected_public_id, :expected_lock_version, :speaker_public_id])
    path = fields[:path]
    return unless not_overridden(@workspace, path: path)

    conversation = find_listable_conversation(@workspace)
    return unless authorize_writable(conversation)

    expected = memory_precondition(fields, allow_absent: false)
    result = ::Conversations::Memory::Apply.delete(
      conversation: conversation, path: path, by: acting_user, expected: expected, speaker: @memory_speaker,
      expected_collection_public_id: memory_collection_precondition(fields)
    )
    return render_refusal(result.outcome) unless result.accepted?

    head :no_content
  end

  private

    # Management applies the stored answerer's standing limit to the host's
    # selected bindings, under the caller's ordinary member visibility.
    def memory_context(conversation)
      MemoryDocuments::Context.new(workspace: conversation.workspace, conversation: conversation,
        principal: acting_user, configuration: conversation.effective_memory_context(speaker: @memory_speaker),
        agent: conversation.answering_agent)
    end

    def resolve_memory_speaker
      public_id = speaker_public_id_parameter(params.fetch(:memory, {})[:speaker_public_id])
      return if public_id.nil?

      @memory_speaker = Speaker.find_by(account_id: acting_user.account_id, public_id: public_id)
      render_refusal(:not_authorized) unless @memory_speaker&.ingress_controlled_by?(acting_user)
    end

    def path_param = params.expect(memory: [:path])[:path]

    def resolve(conversation)
      anchor = memory_context(conversation).resolve(path_param)
      render_refusal(anchor.refusal) unless anchor.resolved?
      anchor
    end
end
