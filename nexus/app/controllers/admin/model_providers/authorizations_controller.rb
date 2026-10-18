class Admin::ModelProviders::AuthorizationsController < Admin::ModelProviders::BaseController
  before_action :require_authorization_lane
  rate_limit to: 10, within: 3.minutes, by: -> { Current.user.id }, only: :create,
    with: -> { redirect_to admin_model_provider_authorization_path(provider_id), alert: t("admin.model_providers.authorization_rate_limited"), status: :see_other }

  def show
    load_authorization
  end

  def create
    fields = params.permit(authorization: [:restart]).fetch(:authorization)
    restart = ActiveModel::Type::Boolean.new.cast(fields[:restart])
    result = ModelProviders::CodexAuthorization::AcceptSession.call(
      account: account, issuing_user: Current.user, provider_id: provider_id,
      kind: "device_start", restart: restart == true
    )
    if result.accepted?
      ModelProviderOAuthSessions::AdvanceJob.perform_later(result.session.public_id)
      redirect_to admin_model_provider_authorization_session_path(provider_id, result.session.public_id), status: :see_other
    else
      load_authorization
      form_error(result.outcome, status: :conflict)
    end
  end

  def destroy
    ModelProviders::CodexAuthorization::ClearAuthorization.call(account: account, provider_id: provider_id)
    redirect_to admin_model_provider_path(provider_id), notice: t("admin.model_providers.authorization_cleared"), status: :see_other
  end

  private

    def require_authorization_lane
      head :not_found unless provider_id == ModelProviders::CodexAuthorization::PROVIDER_ID
    end

    def load_authorization
      @authorization = API::ModelProviderAuthorizationPresenter.current(account: account, provider_id: provider_id, user: Current.user)
    end
end
