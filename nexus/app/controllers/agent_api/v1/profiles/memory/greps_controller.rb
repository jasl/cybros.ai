class AgentAPI::V1::Profiles::Memory::GrepsController < AgentAPI::V1::Profiles::MemoryController
  def create
    fields = params.expect(memory: [:pattern, :path, :ignore_case, :limit])
    context = MemoryDocuments::Context.new(workspace: nil, conversation: nil, principal: acting_user,
      configuration: { "bindings" => [{ "name" => "user", "scope" => "user", "access" => "read_write" }] })
    result = context.search(pattern: fields[:pattern], path: fields[:path],
      ignore_case: ActiveModel::Type::Boolean.new.cast(fields[:ignore_case]), limit: fields[:limit])
    return render_refusal(result.refusal) unless result.found?

    render json: AgentAPI::MemoryPresenter.search(result)
  end
end
