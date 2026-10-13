# THE ACTING USER'S OWN SLOTS: an agent profile holds `system_prompt` —
# its own row, never its steward's — and `summarizer` (its text for the
# kernel-mode compaction summarizer), a Human holds `persona`; anything
# else is refused by name before any row is touched. No fence and no
# workspace: the users row is the caller's and the lock.
class AgentAPI::V1::Profiles::PromptDocumentsController < AgentAPI::V1::BaseController
  serves_plane :member

  def index
    render json: { prompt_documents:
      AgentAPI::PromptDocumentPresenter.listing(acting_user.prompt_documents.order(:slot)) }
  end

  def show
    return unless slot_held?

    document = acting_user.prompt_documents.find_by(slot: params[:slot])
    return render_refusal(:prompt_document_not_found) if document.nil?

    render json: { prompt_document: AgentAPI::PromptDocumentPresenter.full(document) }
  end

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
