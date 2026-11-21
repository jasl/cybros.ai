# The models this account can run — the account's listing, not the catalog's:
# policy overlay applied, each row saying whether it would run and what would
# refuse it first.
# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::ModelsController < API::V1::Admin::BaseController
  # @oas_include
  # @summary List models
  # @tags Platform, models
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminModelsIndex
  # @response_ref (503) #/components/responses/APIError
  def index
    snapshot = ModelCatalog.current
    catalog = ModelSelection::Resolver.effective_catalog(Current.user.account, snapshot)
    models = AgentAPI::ModelPresenter.index(account: Current.user.account, catalog: catalog)
    models = models.select { |model| model.fetch(:workload) == params[:workload] } if
      params[:workload].present?
    models = models.select { |model| model.fetch(:available) } if params[:available] == "true"

    render json: { models: models }
  end
end
