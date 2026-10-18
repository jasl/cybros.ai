class API::V1::Admin::ModelProviders::AuthorizationSessionsController < API::V1::Admin::ModelProviders::BaseController
  def show
    session = ModelProviderOAuthSession.find_by!(
      account_id: account.id, provider_id: provider_id, public_id: params[:id]
    )
    render json: { authorization_session: API::ModelProviderAuthorizationPresenter.session(session, user: Current.user) }
  end
end
