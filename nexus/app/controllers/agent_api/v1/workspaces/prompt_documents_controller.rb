# THE ROOM'S CHARACTER: the workspace door holds the one slot a workspace
# anchors, written under the dedication fence — a fenced second agent reads
# it and never writes it; a browsable-but-archived room still reads. PUT by
# slot in the URL is a whole replacement, first or later write alike; the
# workspaces row is the lock.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::PromptDocumentsController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  SLOTS = %w[character].freeze

  # @oas_include
  # @summary List prompt documents
  # @tags Member, prompt documents
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesPromptDocumentsIndex
  def index
    render json: { prompt_documents:
      AgentAPI::PromptDocumentPresenter.listing(@workspace.prompt_documents.order(:slot)) }
  end

  # @oas_include
  # @summary Read prompt documents
  # @tags Member, prompt documents
  # @parameter slot(path) [!String] Resource selector.
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesPromptDocumentsShow
  def show
    return unless slot_held?

    document = @workspace.prompt_documents.find_by(slot: params[:slot])
    return render_refusal(:prompt_document_not_found) if document.nil?

    render json: { prompt_document: AgentAPI::PromptDocumentPresenter.full(document) }
  end

  # @oas_include
  # @summary Update prompt documents
  # @tags Member, prompt documents
  # @parameter slot(path) [!String] Resource selector.
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesPromptDocumentsUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesPromptDocumentsUpdate
  def update
    return unless slot_held? && authorize_writable(@workspace)

    fields = params.expect(prompt_document: [:content, :role])
    result = PromptDocument.transaction do
      @workspace.lock!
      PromptDocuments::Write.call(anchor: { workspace: @workspace }, slot: params[:slot],
        content: fields[:content], role: fields[:role])
    end
    return render_refusal(result.outcome, detail: result.detail) unless result.written?

    render json: { prompt_document: AgentAPI::PromptDocumentPresenter.full(result.document) }
  end

  # @oas_include
  # @summary Destroy prompt documents
  # @tags Member, prompt documents
  # @parameter slot(path) [!String] Resource selector.
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (204) #/components/responses/AgentApiV1WorkspacesPromptDocumentsDestroy
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  def destroy
    return unless slot_held? && authorize_writable(@workspace)

    result = PromptDocument.transaction do
      @workspace.lock!
      PromptDocuments::Delete.call(anchor: { workspace: @workspace }, slot: params[:slot])
    end
    return render_refusal(result.outcome) unless result.deleted?

    head :no_content
  end

  private

    # Refused before any row is touched: this anchor holds `character` alone.
    def slot_held?
      return true if SLOTS.include?(params[:slot])

      render_refusal(:prompt_slot_unavailable, detail: params[:slot])
      false
    end

    # A write with durable reach: the live-state refusal first (a person
    # reads why), then the fence — a browsable-but-not-writable caller
    # reads and never writes.
    def authorize_writable(workspace)
      return true if workspace.data_writable_by?(acting_user)

      if workspace.live?
        render_error(:not_authorized, "This workspace is not writable by the caller", status: :forbidden)
      else
        render_refusal(:workspace_not_active)
      end
      false
    end
end
