# Personal prompt settings for the authenticated Human, independent of an
# Agent's policy. The member door and assembly read this same document.
class API::V1::PersonasController < API::V1::BaseController
  def show
    document = Current.user.prompt_documents.find_by(slot: "persona")
    return render_refusal(:prompt_document_not_found) if document.nil?

    render json: { prompt_document: AgentAPI::PromptDocumentPresenter.full(document) }
  end

  def update
    fields = params.expect(prompt_document: [:content, :role])
    # The Human anchor serializes whole-slot replacement against both API
    # doors; PromptDocument has no independent lifecycle or lock row.
    result = Current.user.with_lock do
      PromptDocuments::Write.call(anchor: { user: Current.user }, slot: "persona",
        content: fields[:content], role: fields[:role])
    end
    return render_refusal(result.outcome, detail: result.detail) unless result.written?

    render json: { prompt_document: AgentAPI::PromptDocumentPresenter.full(result.document) }
  end

  def destroy
    result = Current.user.with_lock do
      PromptDocuments::Delete.call(anchor: { user: Current.user }, slot: "persona")
    end
    return render_refusal(result.outcome) unless result.deleted?

    head :no_content
  end
end
