class Settings::SsoConnectionsController < Settings::BaseController
  include SsoSettingsAuthentication
  include SsoSettingsAudit
  rate_limit to: 10, within: 3.minutes, by: -> { Current.user.public_id }, scope: "settings/current-password",
    only: :destroy, with: -> { head :too_many_requests }

  def index
    @connections = Current.identity.sso_connections.includes(:sso_provider).index_by(&:sso_provider_id)
    @sources = Current.account.sso_providers.where(enabled: true)
      .or(Current.account.sso_providers.where(id: @connections.keys)).listed
    @selected_id = params.permit(:provider)[:provider].to_s
    selected = @sources.detect { |source| source.public_id == @selected_id }
    if selected
      attached = @connections.key?(selected.id)
      @verified = Sso::Proof.valid?(session: Current.session, action: attached ? "sso_disconnect" : "sso_connect",
        target: selected.public_id, excluding_provider: (selected if attached))
    end
    @available_ids = SsoConnection.available.where(identity: Current.identity).pluck(:sso_provider_id)
    @local_password = !Current.account.sso_only? && Current.identity.password_digest.present? &&
      !Current.identity.password_change_required?
  end

  def destroy
    connection = Current.identity.sso_connections.eager_load(:sso_provider).find_by!(sso_providers: { public_id: params[:id] })
    target = connection.sso_provider.public_id
    if !connection.removable?
      audit_sso_setting(:unlink, target, :refused, reason: :last_login_method)
      redirect_to settings_sso_connections_path, alert: t("sso.last_method"), status: :see_other
      return
    end
    with_sso_settings_proof(action: "sso_disconnect", target: params[:id], excluding_provider: connection.sso_provider) do |verified|
      if !verified
        audit_sso_setting(:unlink, target, :refused, reason: :verification_required)
        redirect_to settings_sso_connections_path, alert: t("sso.verify"), status: :see_other
      elsif connection.disconnect
        audit_sso_setting(:unlink, target, :disconnected)
        redirect_to settings_sso_connections_path, notice: t("sso.disconnected"), status: :see_other
      else
        audit_sso_setting(:unlink, target, :refused, reason: connection.errors.first.type)
        redirect_to settings_sso_connections_path, alert: connection.errors.full_messages.to_sentence, status: :see_other
      end
    end
  end
end
