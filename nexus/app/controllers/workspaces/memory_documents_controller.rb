class Workspaces::MemoryDocumentsController < Workspaces::DataController
  include AgentAPI::MemoryOverrideGuard

  def index
    return unless not_overridden(workspace)

    @entries = MemoryDocuments::Listing.call(documents: MemoryDocument.for_workspace(workspace.id))
  end

  def show
    load_document
  end

  def new
    @draft = { "path" => params.permit(:path)[:path].presence || "workspace/", "content" => "", "description" => "",
      "expected_public_id" => "", "expected_lock_version" => "" }
    not_overridden(workspace, path: @draft["path"])
  end

  def edit
    return unless load_document

    @draft = { "path" => @document.path, "content" => @document.content, "description" => @document.description,
      "expected_public_id" => @document.public_id, "expected_lock_version" => @document.lock_version }
  end

  def create
    write_document(creating: true)
  end

  def update
    write_document(creating: false)
  end

  def destroy
    fields = params.expect(memory: [:path, :expected_public_id, :expected_lock_version]).to_h
    @draft = fields
    @failure_template = "workspaces/memory_documents/delete_error"
    return unless not_overridden(workspace, path: fields["path"])

    anchor = resolve(fields["path"])
    return if performed?

    expected = precondition(fields, allow_absent: false)
    return if performed?

    workspace.with_lock do
      return unless data_write_allowed?(template: @failure_template)

      result = MemoryDocuments::Delete.call(anchor: anchor, expected: expected)
      return render_data_refusal(result.outcome, template: @failure_template) unless result.deleted?
    end
    redirect_to workspace_memory_documents_path(workspace), notice: t("data_console.memory.deleted"), status: :see_other
  end

  private

    def load_document
      path = params.permit(:path)[:path].to_s
      return false unless not_overridden(workspace, path: path)

      anchor = resolve(path)
      return false if performed?

      @document = anchor.documents.eager_load(:memory_document_version).find_by!(name: anchor.name)
      true
    end

    def resolve(path)
      anchor = Scopes::Anchor.call(path: path, workspace: workspace)
      render_data_refusal(anchor.refusal, template: @failure_template || "workspaces/data/refusal") unless anchor.resolved?
      anchor
    end

    def write_document(creating:)
      @draft = params.expect(memory: [:path, :content, :description, :expected_public_id, :expected_lock_version]).to_h
      @failure_template = creating ? :new : :edit
      return unless not_overridden(workspace, path: @draft["path"])

      anchor = resolve(@draft["path"])
      return if performed?

      expected = precondition(@draft, allow_absent: creating)
      return if performed?

      workspace.with_lock do
        return unless data_write_allowed?(template: @failure_template)

        result = MemoryDocuments::Write.call(anchor: anchor, content: @draft["content"],
          description: @draft["description"].presence, expected: expected)
        return render_data_refusal(result.outcome, template: @failure_template) unless result.written?
      end
      redirect_to workspace_memory_document_path(workspace, path: @draft["path"]),
        notice: t("data_console.memory.saved"), status: :see_other
    end

    def precondition(fields, allow_absent:)
      values = fields.slice("expected_public_id", "expected_lock_version")
      if allow_absent && values.values_at("expected_public_id", "expected_lock_version") == ["", ""]
        values.transform_values! { nil }
      end
      MemoryDocuments::Precondition.parse(values, allow_absent: allow_absent)
    rescue KeyError, ArgumentError
      render_data_refusal(:invalid_precondition, template: @failure_template)
      nil
    end

    # Share the API's override decision, including its exact skills-path exception.
    def render_error(code, _message, status:)
      @memory_overridden = true
      @provider = workspace.tool_provider_for("memory_read")&.display_name || workspace.tool_provider_override_for("memory_read")
      render_data_refusal(code, template: @failure_template || "workspaces/data/refusal", status: status, detail: @provider)
    end
end
