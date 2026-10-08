class AgentAPI::V1::Workspaces::Memory::GrepsController < AgentAPI::V1::Workspaces::MemoryController
  def create
    fields = params.expect(memory: [:pattern, :path, :ignore_case, :limit])
    return unless not_overridden(@workspace, path: fields[:path])

    context = MemoryDocuments::Context.new(workspace: @workspace, conversation: nil, principal: acting_user,
      configuration: { "bindings" => [{ "name" => "workspace", "scope" => "workspace", "access" => "read_write" }] })
    result = context.search(pattern: fields[:pattern], path: fields[:path],
      ignore_case: ActiveModel::Type::Boolean.new.cast(fields[:ignore_case]),
      limit: limit_param(value: fields[:limit], default: MemoryDocuments::Search::DEFAULT_LIMIT,
        max: MemoryDocuments::Search::MAX_LIMIT))
    return render_refusal(result.refusal) unless result.found?

    render json: AgentAPI::MemoryPresenter.search(result)
  end
end
