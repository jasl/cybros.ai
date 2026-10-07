# The provider lanes this account holds — the other half of `models`: a model
# runs only once its lane is enabled and credentialed by an administrator.
class AgentAPI::V1::ModelProvidersController < AgentAPI::V1::BaseController
  serves_plane :member

  def index
    render json: {
      model_providers: AgentAPI::ModelProviderPresenter.index(
        account: current_credential.user.account, snapshot: ModelCatalog.current, now: DatabaseClock.now
      ),
    }
  end
end
