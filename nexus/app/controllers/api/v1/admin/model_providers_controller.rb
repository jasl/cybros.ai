# Account-level model operations are owned by Human administrators.
class API::V1::Admin::ModelProvidersController < API::V1::Admin::ModelProviders::BaseController
  def index
    render json: {
      model_providers: AgentAPI::ModelProviderPresenter.index(
        account: account, snapshot: snapshot, now: DatabaseClock.now
      ),
    }
  end

  def show
    render_configuration
  end
end
