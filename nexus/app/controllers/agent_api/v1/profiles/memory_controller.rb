# The caller's own document door: user/ for a Human, agent/ for an Agent.
# A named definition's subclass uses that definition's Agent anchor. Speaker
# memory needs a conversation's explicit subject or an execution's capture,
# so this profile-only door does not infer one.
class AgentAPI::V1::Profiles::MemoryController < AgentAPI::V1::BaseController
  serves_plane :member
  include AgentAPI::MemoryPreconditions

  def index
    render json: { memory: AgentAPI::MemoryPresenter.listing(context.listing) }
  end

  def show
    path = path_param
    anchor = resolve(path)
    return if performed?

    document = anchor.documents.eager_load(:memory_document_version).find_by(name: anchor.name)
    return render_refusal(:memory_not_found) if document.nil?

    render json: { memory: AgentAPI::MemoryPresenter.full(document, path: path) }
  end

  # The users row is the host — one lock, no conversation, no fence.
  # `revises` is nil because no conversation assembles from this row by
  # pointer: the next turn of ANY conversation reads it live (each turn
  # freezes its assembled block). `description` is a skill row's
  # (`user/skills/<name>`, `agent/skills/<name>`) — the writer rules it.
  def create
    fields = params.expect(memory: [:path, :content, :description, :expected_public_id, :expected_lock_version])
    anchor = resolve(fields[:path], authoring: true)
    return if performed?

    expected = memory_precondition(fields, allow_absent: true)
    result = MemoryDocument.transaction do
      anchor.lockable.lock!
      MemoryDocuments::Write.call(anchor: anchor, content: fields[:content], expected: expected,
        description: fields[:description])
    end
    return render_refusal(result.outcome) unless result.written?

    render json: { memory: AgentAPI::MemoryPresenter.full(result.document, path: fields[:path]) },
      status: :created
  end

  def delete
    fields = params.expect(memory: [:path, :expected_public_id, :expected_lock_version])
    anchor = resolve(fields[:path], authoring: true)
    return if performed?

    expected = memory_precondition(fields, allow_absent: false)
    result = MemoryDocument.transaction do
      anchor.lockable.lock!
      MemoryDocuments::Delete.call(anchor: anchor, expected: expected)
    end
    return render_refusal(result.outcome) unless result.deleted?

    head :no_content
  end

  private

    def acting_user = current_credential.user

    # The agent rung at this door: the caller's own row, a paired program's
    # alone — a Human answers for nobody and has none.
    def agent = (acting_user if acting_user.agent_member?)

    def bindings
      rungs = []
      rungs << { "name" => "user", "scope" => "user", "access" => "read_write" } if acting_user.human?
      rungs << { "name" => "agent", "scope" => "agent", "access" => "read_write" } if agent
      rungs
    end

    # No workspace and no conversation are passed: the other two scopes
    # answer `memory_scope_unavailable` at this door by construction.
    def context
      @context ||= MemoryDocuments::Context.new(workspace: nil, conversation: nil, principal: acting_user,
        configuration: MemoryContext.constrain(configuration: { "bindings" => bindings }, limit: agent&.memory_context_limit), agent: agent)
    end

    def path_param = params.expect(memory: [:path])[:path]

    def resolve(path, authoring: false)
      anchor = context.resolve(path, authoring: authoring)
      render_refusal(anchor.refusal) unless anchor.resolved?
      anchor
    end
end
