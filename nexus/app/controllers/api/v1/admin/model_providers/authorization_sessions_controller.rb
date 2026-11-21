# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::ModelProviders::AuthorizationSessionsController < API::V1::Admin::ModelProviders::BaseController
  # @oas_include
  # @summary Read authorization sessions
  # @tags Platform, authorization sessions
  # @parameter id(path) [!String] Resource selector.
  # @parameter model_provider_id(path) [!String] Resource selector.
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminModelProvidersAuthorizationSessionsShow
  def show
    session = ModelProviderOAuthSession.find_by!(
      account_id: account.id, provider_id: provider_id, public_id: params[:id]
    )
    render json: { authorization_session: API::ModelProviderAuthorizationPresenter.session(session, user: Current.user) }
  end
end
