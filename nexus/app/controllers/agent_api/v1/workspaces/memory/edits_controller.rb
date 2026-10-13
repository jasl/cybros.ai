class AgentAPI::V1::Workspaces::Memory::EditsController < AgentAPI::V1::Workspaces::MemoryController
  def create
    fields = params.expect(memory: [:path, :old_text, :new_text, :expected_public_id, :expected_lock_version])
    return unless not_overridden(@workspace, path: fields[:path]) && authorize_writable(@workspace)

    anchor = resolve(fields[:path])
    return if performed?

    expected = memory_precondition(fields, allow_absent: false)
    result = MemoryDocument.transaction do
      anchor.lockable.lock!
      MemoryDocuments::Edit.call(anchor: anchor, old_text: fields[:old_text],
        new_text: fields[:new_text], expected: expected)
    end
    return render_refusal(result.outcome) unless result.written?

    render json: { memory: AgentAPI::MemoryPresenter.full(result.document) }
  end
end
