class Admin::SsoProviders::DeletionsController < Admin::BaseController
  def show
    @provider = Current.account.sso_providers.find_by!(public_id: params[:sso_provider_id])
    if Current.account.sso_only? || @provider.enabled?
      redirect_to admin_sso_provider_path(@provider), alert: t(Current.account.sso_only? ? "sso.deletion_forbidden" : "sso.disable_first")
      return
    end
    @bindings = @provider.sso_connections.joins(identity: :user).group("users.status").count
    @blocked = @provider.uncovered_users_if_disabled.exists?
    dormant = @provider.uncovered_users_if_disabled(statuses: [:suspended, :removed]).includes(:identity).order(:display_name, :id)
    @dormant_pagy, @dormant = pagy(:offset, dormant, limit: 25)
  end
end
