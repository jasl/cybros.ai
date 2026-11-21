# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::ModelProviders::AuthorizationsController < API::V1::Admin::ModelProviders::BaseController
  before_action :require_authorization_lane
  rate_limit to: 10, within: 3.minutes, by: -> { Current.user.id }, only: :create

  # @oas_include
  # @summary Read authorizations
  # @tags Platform, authorizations
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
  # @response_ref (200) #/components/responses/ApiV1AdminModelProvidersAuthorizationsShow
  def show
    render_authorization
  end

  # @oas_include
  # @summary Create authorizations
  # @tags Platform, authorizations
  # @parameter model_provider_id(path) [!String] Resource selector.
  # @request_body_ref #/components/requestBodies/ApiV1AdminModelProvidersAuthorizationsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (202) #/components/responses/ApiV1AdminModelProvidersAuthorizationsCreate
  def create
    fields = params.permit(command: [:restart]).fetch(:command)
    restart = ActiveModel::Type::Boolean.new.cast(fields[:restart])
    result = ModelProviders::CodexAuthorization::AcceptSession.call(
      account: account, issuing_user: Current.user, provider_id: provider_id,
      kind: "device_start", restart: restart == true
    )
    return render_refusal(result.outcome) unless result.accepted?

    session = result.session
    ModelProviderOAuthSessions::AdvanceJob.perform_later(session.public_id)
    render json: { authorization_session: API::ModelProviderAuthorizationPresenter.session(session, user: Current.user) },
      status: :accepted,
      location: api_v1_admin_model_provider_authorization_session_url(provider_id, session.public_id)
  end

  # @oas_include
  # @summary Destroy authorizations
  # @tags Platform, authorizations
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
  # @response_ref (200) #/components/responses/ApiV1AdminModelProvidersAuthorizationsDestroy
  def destroy
    ModelProviders::CodexAuthorization::ClearAuthorization.call(account: account, provider_id: provider_id)
    render_authorization
  end

  private

    def render_authorization
      render json: { authorization: API::ModelProviderAuthorizationPresenter.current(account: account, provider_id: provider_id, user: Current.user) }
    end

    def require_authorization_lane
      unless provider_id == ModelProviders::CodexAuthorization::PROVIDER_ID
        render_refusal(:authorization_not_supported)
      end
    end
end
