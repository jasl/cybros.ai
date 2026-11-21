class Admin::SsoProviders::ActivationsController < Admin::BaseController
  include SsoSettingsAudit
  around_action :require_sso_admin_write
  before_action :set_provider

  def create
    change_enabled(true)
  end

  def destroy
    change_enabled(false)
  end

  private

    def set_provider
      @provider = Current.account.sso_providers.find_by!(public_id: params[:sso_provider_id])
    end

    def change_enabled(value)
      version = Integer(params.permit(:lock_version)[:lock_version], exception: false)
      action = value ? :enable_provider : :disable_provider
      if @provider.set_enabled(value, expected_version: version)
        audit_sso_setting(action, @provider.public_id, :saved)
        redirect_to admin_sso_provider_path(@provider), notice: t("sso.saved"), status: :see_other
      else
        audit_sso_setting(action, @provider.public_id, :refused, reason: @provider.errors.first.type)
        redirect_to admin_sso_provider_path(@provider), alert: @provider.errors.full_messages.to_sentence, status: :see_other
      end
    end
end
