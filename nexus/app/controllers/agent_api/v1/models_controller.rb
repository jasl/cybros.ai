# The models this account can run — the account's listing, not the catalog's:
# policy overlay applied and unavailable models omitted. Operators diagnose
# the full catalog through the platform administration surface.
class AgentAPI::V1::ModelsController < AgentAPI::V1::BaseController
  serves_plane :member

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
