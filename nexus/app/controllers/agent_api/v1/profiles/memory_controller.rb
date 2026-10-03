# THE PERSON'S OWN DOOR to memory's `user/` scope: the scope follows the
# acting user's controlling Human, so an agent writes its steward's notes
# here and reads them from any workspace; `workspace/` and `conversation/`
# have their own doors and are refused at this one. No fence and no
# writability check: the scope is the caller's own Human's, and every
# member of that Human's circle writes it. Paths ride the body
# (`user/notes.md` survives no routing convention).
class AgentAPI::V1::Profiles::MemoryController < AgentAPI::V1::BaseController
  serves_plane :member
  include AgentAPI::MemoryPreconditions

  def index
    documents = human ? MemoryDocument.for_user(human.id) : MemoryDocument.none
    entries = MemoryDocuments::Listing.call(documents: documents)
    render json: { memory: AgentAPI::MemoryPresenter.listing(entries) }
  end

  def show
    anchor = resolve
    return if performed?

    document = anchor.documents.eager_load(:memory_document_version).find_by(name: anchor.name)
    return render_refusal(:memory_not_found) if document.nil?

    render json: { memory: AgentAPI::MemoryPresenter.full(document) }
  end

  # The users row is the host — one lock, no conversation, no fence.
  # `revises` is nil because no conversation assembles from this row by
  # pointer: the next turn of ANY conversation reads it live (each turn
  # freezes its assembled block). `description` is a skill row's
  # (`user/skills/<name>`) — the writer rules it.
  def create
    fields = params.expect(memory: [:path, :content, :description, :expected_public_id, :expected_lock_version])
    anchor = resolve(fields[:path])
    return if performed?

    expected = memory_precondition(fields, allow_absent: true)
    result = MemoryDocument.transaction do
      anchor.lockable.lock!
      MemoryDocuments::Write.call(anchor: anchor, content: fields[:content], expected: expected,
        description: fields[:description])
    end
    return render_refusal(result.outcome) unless result.written?

    render json: { memory: AgentAPI::MemoryPresenter.full(result.document) },
      status: :created
  end

  def delete
    fields = params.expect(memory: [:path, :expected_public_id, :expected_lock_version])
    anchor = resolve(fields[:path])
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

    # Nil only for a principal answering to no Human — unreachable through a
    # member credential, which `steward_live?` gates, but never a nil deref.
    def human = acting_user.controlling_human

    # No workspace and no conversation are passed: the other two scopes
    # answer `memory_scope_unavailable` at this door by construction.
    def resolve(path = params.expect(memory: [:path])[:path])
      anchor = Scopes::Anchor.call(path: path, user: human)
      render_refusal(anchor.refusal) unless anchor.resolved?
      anchor
    end
end
