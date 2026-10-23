class MemoryCollections::DocumentsController < MemoryCollectionsController
  include AgentAPI::MemoryOverrideGuard
  before_action :load_collection

  def index
    return unless content_available?

    @entries = MemoryDocuments::Listing.call(documents: @collection.memory_documents, paths: ->(_id, name) { [name] })
  end

  def show
    load_document
  end

  def new
    @draft = { "path" => params.permit(:path)[:path].to_s, "content" => "", "description" => "",
      "expected_public_id" => "", "expected_lock_version" => "" }
    content_available?(@draft["path"])
  end

  def edit
    return unless load_document

    @draft = { "path" => @document.name, "content" => @document.content, "description" => @document.description,
      "expected_public_id" => @document.public_id, "expected_lock_version" => @document.lock_version }
  end

  def create = write_document(creating: true)
  def update = write_document(creating: false)

  def destroy
    @draft = params.expect(memory: [:path, :expected_public_id, :expected_lock_version]).to_h
    @failure_template = "memory_collections/documents/delete_error"
    return unless content_available?(@draft["path"])

    expected = precondition(@draft, allow_absent: false)
    return if performed?

    result = commands.apply(@draft["path"]) { |anchor| MemoryDocuments::Delete.call(anchor: anchor, expected: expected) }
    return render_refusal(result.outcome, template: @failure_template) unless result.outcome == :deleted

    redirect_to memory_collection_documents_path(@collection), notice: t("data_console.memory.deleted"), status: :see_other
  end

  private

    def commands = MemoryCollections::Documents.new(collection: @collection, by: Current.user)

    def content_available?(path = nil)
      workspace = @collection.workspace || @collection.conversation&.workspace
      workspace.nil? || not_overridden(workspace, path: ("#{@collection.natural_scope}/#{path}" if path))
    end

    def load_document
      path = params.permit(:path)[:path].to_s
      return false unless content_available?(path)

      @document = @collection.memory_documents.eager_load(:memory_document_version).find_by!(name: path)
      true
    end

    def write_document(creating:)
      @draft = params.expect(memory: [:path, :content, :description, :expected_public_id, :expected_lock_version]).to_h
      @failure_template = creating ? :new : :edit
      return unless content_available?(@draft["path"])

      expected = precondition(@draft, allow_absent: creating)
      return if performed?

      result = commands.apply(@draft["path"]) do |anchor|
        MemoryDocuments::Write.call(anchor: anchor, content: @draft["content"],
          description: @draft["description"].presence, expected: expected)
      end
      return render_refusal(result.outcome, template: @failure_template) unless result.written?

      redirect_to memory_collection_document_path(@collection, path: @draft["path"]),
        notice: t("data_console.memory.saved"), status: :see_other
    end

    def precondition(fields, allow_absent:)
      values = fields.slice("expected_public_id", "expected_lock_version")
      if allow_absent && values.values_at("expected_public_id", "expected_lock_version") == ["", ""]
        values.transform_values! { nil }
      end
      MemoryDocuments::Precondition.parse(values, allow_absent: allow_absent)
    rescue KeyError, ArgumentError
      render_refusal(:invalid_precondition, template: @failure_template)
      nil
    end

    def render_error(code, _message, status:)
      @memory_overridden = true
      workspace = @collection.workspace || @collection.conversation.workspace
      provider = workspace.tool_provider_for("memory_read")&.display_name || workspace.tool_provider_override_for("memory_read")
      render_refusal(code, template: @failure_template || "memory_collections/refusal", status: status, detail: provider)
    end
end
