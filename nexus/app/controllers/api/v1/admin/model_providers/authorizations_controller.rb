class API::V1::Admin::ModelProviders::AuthorizationsController < API::V1::Admin::ModelProviders::BaseController
  before_action :require_authorization_lane
  rate_limit to: 10, within: 3.minutes, by: -> { Current.user.id }, only: :create

  def show
    render_authorization
  end

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
