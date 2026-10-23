class AgentAPI::V1::MemoryCollections::Documents::GrepsController < AgentAPI::V1::MemoryCollections::DocumentsController
  def create
    fields = params.expect(memory: [:pattern, :path, :ignore_case, :limit])
    return unless content_available?(fields[:path])

    result = MemoryDocuments::Search.call(documents: collection.memory_documents, pattern: fields[:pattern], path_prefix: fields[:path],
      ignore_case: ActiveModel::Type::Boolean.new.cast(fields[:ignore_case]),
      limit: limit_param(value: fields[:limit], default: MemoryDocuments::Search::DEFAULT_LIMIT, max: MemoryDocuments::Search::MAX_LIMIT),
      paths: ->(document) { [document.name] })
    result.found? ? render(json: AgentAPI::MemoryPresenter.search(result)) : render_refusal(result.refusal)
  end
end
