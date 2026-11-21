# Personal prompt settings for the authenticated Human, independent of an
# Agent's policy. The member door and assembly read this same document.
# @auth [PlatformBearer, BrowserSession]
class API::V1::PersonasController < API::V1::BaseController
  # @oas_include
  # @summary Read personas
  # @tags Platform, personas
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1PersonasShow
  def show
    document = Current.user.prompt_documents.find_by(slot: "persona")
    return render_refusal(:prompt_document_not_found) if document.nil?

    render json: { prompt_document: AgentAPI::PromptDocumentPresenter.full(document) }
  end

  # @oas_include
  # @summary Update personas
  # @tags Platform, personas
  # @request_body_ref #/components/requestBodies/ApiV1PersonasUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1PersonasUpdate
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

  # @oas_include
  # @summary Destroy personas
  # @tags Platform, personas
  # @response_ref (204) #/components/responses/ApiV1PersonasDestroy
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
    result = Current.user.with_lock do
      PromptDocuments::Delete.call(anchor: { user: Current.user }, slot: "persona")
    end
    return render_refusal(result.outcome) unless result.deleted?

    head :no_content
  end
end
