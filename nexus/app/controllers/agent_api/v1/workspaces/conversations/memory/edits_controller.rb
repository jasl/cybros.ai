class AgentAPI::V1::Workspaces::Conversations::Memory::EditsController <
      AgentAPI::V1::Workspaces::Conversations::MemoryController
  def create
    fields = params.expect(memory: [:path, :old_text, :new_text, :expected_public_id, :expected_lock_version])
    return unless not_overridden(@workspace, path: fields[:path])

    conversation = find_listable_conversation(@workspace)
    return unless authorize_writable(conversation)

    expected = memory_precondition(fields, allow_absent: false)
    result = ::Conversations::Memory::Apply.edit(conversation: conversation, path: fields[:path],
      old_text: fields[:old_text], new_text: fields[:new_text], by: acting_user, expected: expected)
    return render_refusal(result.outcome) unless result.accepted?

    render json: { memory: AgentAPI::MemoryPresenter.full(result.value, path: fields[:path]) }
  end
end
