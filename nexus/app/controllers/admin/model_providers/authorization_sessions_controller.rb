class Admin::ModelProviders::AuthorizationSessionsController < Admin::ModelProviders::AuthorizationsController
  def show
    load_authorization
    session = ModelProviderOAuthSession.find_by!(account: account, provider_id: provider_id, public_id: params[:id])
    @authorization_session = API::ModelProviderAuthorizationPresenter.session(session, user: Current.user)
  end
end
