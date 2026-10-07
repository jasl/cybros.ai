# The conversation plane's only memory writer: a `direct_reply` has no tools,
# so memory reaches its model through the assembly block via here. Paths ride
# in the body — `workspace/notes.md` survives no routing convention. Three
# scopes: the `user/` rung is the CALLER's controlling Human's, resolved and
# rendered exactly as the block does for the turn this caller would post.
# WHILE THE WORKSPACE IS OVERRIDDEN the whole door refuses
# `memory_overridden` (409, naming the provider) for reads and writes — the
# `user/` rung included, which the person's own door (`profile/memory`) keeps
# serving; the kernel's rows wait for the clear. The guard is
# `MemoryOverrideGuard`, shared with the room's own door
# (`workspaces/{id}/memory`, the `workspace/` scope without a conversation).
class AgentAPI::V1::Workspaces::Conversations::MemoryController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include AgentAPI::MemoryOverrideGuard
  include AgentAPI::MemoryPreconditions

  def index
    return unless not_overridden(@workspace)

    conversation = find_listable_conversation(@workspace)

    entries = memory_context(conversation).listing
    render json: { memory: AgentAPI::MemoryPresenter.listing(entries) }
  end

  def show
    return unless not_overridden(@workspace, path: path_param)

    conversation = find_listable_conversation(@workspace)
    anchor = resolve(conversation)
    return if performed?

    document = anchor.documents.eager_load(:memory_document_version).find_by(name: anchor.name)
    return render_refusal(:memory_not_found) if document.nil?

    render json: { memory: AgentAPI::MemoryPresenter.full(document).merge(path: path_param) }
  end

  def create
    fields = params.expect(memory: [:path, :content, :description, :expected_public_id, :expected_lock_version])
    return unless not_overridden(@workspace, path: fields[:path])

    conversation = find_listable_conversation(@workspace)
    return unless authorize_writable(conversation)

    expected = memory_precondition(fields, allow_absent: true)
    result = ::Conversations::Memory::Apply.write(
      conversation: conversation, path: fields[:path], content: fields[:content],
      by: acting_user, expected: expected, description: fields[:description]
    )
    return render_refusal(result.outcome) unless result.accepted?

    render json: { memory: AgentAPI::MemoryPresenter.full(result.value).merge(path: fields[:path]) },
      status: :created
  end

  def delete
    fields = params.expect(memory: [:path, :expected_public_id, :expected_lock_version])
    path = fields[:path]
    return unless not_overridden(@workspace, path: path)

    conversation = find_listable_conversation(@workspace)
    return unless authorize_writable(conversation)

    expected = memory_precondition(fields, allow_absent: false)
    result = ::Conversations::Memory::Apply.delete(
      conversation: conversation, path: path, by: acting_user, expected: expected
    )
    return render_refusal(result.outcome) unless result.accepted?

    head :no_content
  end

  private

    # The same three the assembly block reads for the turn THIS caller
    # would post: the conversation's own documents, its workspace's, and
    # the caller's controlling Human's `user/` — never another Human's.
    def memory_context(conversation)
      MemoryDocuments::Context.new(workspace: conversation.workspace, conversation: conversation,
        principal: acting_user, configuration: conversation.memory_context)
    end

    def path_param = params.expect(memory: [:path])[:path]

    def resolve(conversation)
      anchor = memory_context(conversation).resolve(path_param)
      render_refusal(anchor.refusal) unless anchor.resolved?
      anchor
    end
end
