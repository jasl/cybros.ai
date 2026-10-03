class AgentAPI::V1::Workspaces::Conversations::Memory::GrepsController <
      AgentAPI::V1::Workspaces::Conversations::MemoryController
  def create
    fields = params.expect(memory: [:pattern, :path, :ignore_case, :limit])
    return unless not_overridden(@workspace, path: fields[:path])

    conversation = find_listable_conversation(@workspace)
    result = memory_context(conversation).search(pattern: fields[:pattern], path: fields[:path],
      ignore_case: ActiveModel::Type::Boolean.new.cast(fields[:ignore_case]), limit: fields[:limit])
    return render_refusal(result.refusal) unless result.found?

    render json: AgentAPI::MemoryPresenter.search(result)
  end
end
