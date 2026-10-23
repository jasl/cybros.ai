class AgentAPI::V1::MemoryCollections::DocumentsController < AgentAPI::V1::MemoryCollections::BaseController
  include AgentAPI::MemoryOverrideGuard
  include AgentAPI::MemoryPreconditions

  def index
    return unless content_available?

    entries = MemoryDocuments::Listing.call(documents: collection.memory_documents, paths: ->(_id, name) { [name] })
    render json: { memory: AgentAPI::MemoryPresenter.listing(entries) }
  end

  def show
    path = params.expect(memory: [:path])[:path]
    return unless content_available?(path)

    document = collection.memory_documents.eager_load(:memory_document_version).find_by(name: path)
    return render_refusal(:memory_not_found) unless document

    render json: { memory: AgentAPI::MemoryPresenter.full(document, path: path) }
  end

  def create
    fields = params.expect(memory: [:path, :content, :description, :expected_public_id, :expected_lock_version])
    return unless content_available?(fields[:path])

    expected = memory_precondition(fields, allow_absent: true)
    result = document_commands.apply(fields[:path]) do |anchor|
      MemoryDocuments::Write.call(anchor: anchor, content: fields[:content], description: fields[:description], expected: expected)
    end
    render_document(result, fields[:path], status: :created)
  end

  def delete
    fields = params.expect(memory: [:path, :expected_public_id, :expected_lock_version])
    return unless content_available?(fields[:path])

    expected = memory_precondition(fields, allow_absent: false)
    result = document_commands.apply(fields[:path]) { |anchor| MemoryDocuments::Delete.call(anchor: anchor, expected: expected) }
    result.outcome == :deleted ? head(:no_content) : render_refusal(result.outcome)
  end

  private

    def document_commands = ::MemoryCollections::Documents.new(collection: collection, by: acting_user)

    def content_available?(path = nil)
      workspace = collection.workspace || collection.conversation&.workspace
      workspace.nil? || not_overridden(workspace, path: ("#{collection.natural_scope}/#{path}" if path))
    end

    def render_document(result, path, status: :ok)
      if result.written?
        render json: { memory: AgentAPI::MemoryPresenter.full(result.document, path: path) }, status: status
      else
        render_refusal(result.outcome)
      end
    end
end
