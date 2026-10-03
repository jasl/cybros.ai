# The models this account can run — the account's listing, not the catalog's:
# policy overlay applied, each row saying whether it would run and what would
# refuse it first.
class API::V1::Admin::ModelsController < API::V1::Admin::BaseController
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
