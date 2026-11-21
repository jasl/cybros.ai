# The models this account can run — the account's listing, not the catalog's:
# policy overlay applied and unavailable models omitted. Operators diagnose
# the full catalog through the platform administration surface.
# @auth [MemberBearer]
class AgentAPI::V1::ModelsController < AgentAPI::V1::BaseController
  serves_plane :member

  # @oas_include
  # @summary List models
  # @tags Member, models
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ModelsIndex
  # @response_ref (503) #/components/responses/APIError
  def index
    snapshot = ModelCatalog.current
    catalog = ModelSelection::Resolver.effective_catalog(current_credential.user.account, snapshot)
    models = AgentAPI::ModelPresenter.index(account: current_credential.user.account, catalog: catalog)
    models = models.select { |model| model.fetch(:workload) == params[:workload] } if
      params[:workload].present?
    models = models.select { |model| model.fetch(:available) }

    render json: { models: models }
  end
end
