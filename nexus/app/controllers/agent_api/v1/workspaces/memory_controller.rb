# THE ROOM'S OWN DOOR to memory's `workspace/` scope:
# the rows every conversation of the workspace
# assembles from, written and read without picking a conversation — the
# profile door's shape on the workspace's anchor. `user/` and
# `conversation/` have their own doors and are refused here by
# construction (no user, no conversation is passed to the resolver). Paths
# ride the body (`workspace/notes.md` survives no routing convention).
#
# WHO may write: WRITE standing on the workspace — data access under the
# dedication fence, in `active`; a browsable-but-not-writable caller (an
# archived room's reader, a fenced agent) reads and never writes. The
# workspaces row is the lock; no conversation's `context_revision` is
# bumped — every next turn reads the room's rows live (each turn freezes
# the assembled block). The override guard is the conversation door's,
# shared (`MemoryOverrideGuard`).
class AgentAPI::V1::Workspaces::MemoryController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include AgentAPI::MemoryOverrideGuard
  include AgentAPI::MemoryPreconditions

  def index
    return unless not_overridden(@workspace)

    entries = MemoryDocuments::Listing.call(documents: MemoryDocument.for_workspace(@workspace.id))
    render json: { memory: AgentAPI::MemoryPresenter.listing(entries) }
  end

  def show
    return unless not_overridden(@workspace, path: path_param)

    anchor = resolve(path_param)
    return if performed?

    document = anchor.documents.eager_load(:memory_document_version).find_by(name: anchor.name)
    return render_refusal(:memory_not_found) if document.nil?

    render json: { memory: AgentAPI::MemoryPresenter.full(document) }
  end

  # `description` is a skill row's (`workspace/skills/<name>`, capabilities
  # II 3.3) — the writer rules it.
  def create
    fields = params.expect(memory: [:path, :content, :description, :expected_public_id, :expected_lock_version])
    return unless not_overridden(@workspace, path: fields[:path]) && authorize_writable(@workspace)

    anchor = resolve(fields[:path])
    return if performed?

    expected = memory_precondition(fields, allow_absent: true)
    result = MemoryDocument.transaction do
      anchor.lockable.lock!
      MemoryDocuments::Write.call(anchor: anchor, content: fields[:content], expected: expected, description: fields[:description])
    end
    return render_refusal(result.outcome) unless result.written?

    render json: { memory: AgentAPI::MemoryPresenter.full(result.document) }, status: :created
  end

  def delete
    fields = params.expect(memory: [:path, :expected_public_id, :expected_lock_version])
    path = fields[:path]
    return unless not_overridden(@workspace, path: path) && authorize_writable(@workspace)

    anchor = resolve(path)
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

    def path_param = params.expect(memory: [:path])[:path]

    # The workspace alone is passed: the other two scopes answer
    # `memory_scope_unavailable` at this door by construction.
    def resolve(path)
      anchor = Scopes::Anchor.call(path: path, workspace: @workspace)
      render_refusal(anchor.refusal) unless anchor.resolved?
      anchor
    end
end
