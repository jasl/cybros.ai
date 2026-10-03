class Admin::ModelProviders::APIKeysController < Admin::ModelProviders::BaseController
  before_action :require_api_key_lane

  def show
  end

  def update
    fields = params.expect(credential: [:api_key])
    result = ModelProviders::ConfigureAPIKey.call(account: account, provider_id: provider_id, api_key: fields[:api_key])
    if result.done?
      redirect_to admin_model_provider_path(provider_id), notice: t("admin.model_providers.key_saved"), status: :see_other
    else
      form_error(:invalid_key)
    end
  end

  def destroy
    result = ModelProviders::RemoveAPIKey.call(account: account, provider_id: provider_id)
    if result.done? || result.outcome == :not_found
      redirect_to admin_model_provider_path(provider_id), notice: t("admin.model_providers.key_removed"), status: :see_other
    else
      form_error(:invalid_key)
    end
  end

  private

    def require_api_key_lane
      head :not_found unless @provider.fetch(:credentials) == "api_key"
    end
end
