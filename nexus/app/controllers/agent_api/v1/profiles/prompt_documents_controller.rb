# THE ACTING USER'S OWN SLOTS: an agent profile holds `system_prompt` —
# its own row, never its steward's — and `summarizer` (its text for the
# kernel-mode compaction summarizer), a Human holds `persona`; anything
# else is refused by name before any row is touched. No fence and no
# workspace: the users row is the caller's and the lock.
# @auth [MemberBearer]
class AgentAPI::V1::Profiles::PromptDocumentsController < AgentAPI::V1::BaseController
  serves_plane :member

  # @oas_include
  # @summary List prompt documents
  # @tags Member, prompt documents
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ProfilesPromptDocumentsIndex
  def index
    render json: { prompt_documents:
      AgentAPI::PromptDocumentPresenter.listing(acting_user.prompt_documents.order(:slot)) }
  end

  # @oas_include
  # @summary Read prompt documents
  # @tags Member, prompt documents
  # @parameter slot(path) [!String] Resource selector.
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ProfilesPromptDocumentsShow
  def show
    return unless slot_held?

    document = acting_user.prompt_documents.find_by(slot: params[:slot])
    return render_refusal(:prompt_document_not_found) if document.nil?

    render json: { prompt_document: AgentAPI::PromptDocumentPresenter.full(document) }
  end

  # @oas_include
  # @summary Update prompt documents
  # @tags Member, prompt documents
  # @parameter slot(path) [!String] Resource selector.
  # @request_body_ref #/components/requestBodies/AgentApiV1ProfilesPromptDocumentsUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ProfilesPromptDocumentsUpdate
  def update
    return unless slot_held?

    fields = params.expect(prompt_document: [:content, :role])
    result = PromptDocument.transaction do
      acting_user.lock!

      PromptDocuments::Write.call(anchor: { user: acting_user }, slot: params[:slot],
        content: fields[:content], role: fields[:role])
    end
    return render_refusal(result.outcome, detail: result.detail) unless result.written?

    render json: { prompt_document: AgentAPI::PromptDocumentPresenter.full(result.document) }
  end

  # @oas_include
  # @summary Destroy prompt documents
  # @tags Member, prompt documents
  # @parameter slot(path) [!String] Resource selector.
  # @response_ref (204) #/components/responses/AgentApiV1ProfilesPromptDocumentsDestroy
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
    return unless slot_held?

    result = PromptDocument.transaction do
      acting_user.lock!

      PromptDocuments::Delete.call(anchor: { user: acting_user }, slot: params[:slot])
    end
    return render_refusal(result.outcome) unless result.deleted?

    head :no_content
  end

  private

    def acting_user = current_credential.user

    # The slots this User's kind anchors (PromptDocument::SLOT_ANCHORS): an
    # agent's `system_prompt` and `summarizer`, a Human's `persona`.
    def slot_held?
      held = PromptDocument.slots_anchored(acting_user.agent? ? :agent : :human)
      return true if held.include?(params[:slot])

      render_refusal(:prompt_slot_unavailable, detail: params[:slot])
      false
    end
end
