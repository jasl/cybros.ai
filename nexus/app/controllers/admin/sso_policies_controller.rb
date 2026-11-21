class Admin::SsoPoliciesController < Admin::BaseController
  include SsoSettingsAuthentication
  include SsoSettingsAudit
  rate_limit to: 10, within: 3.minutes, by: -> { Current.user.public_id }, scope: "settings/current-password",
    with: -> { head :too_many_requests }

  def update
    case params.permit(:mode)[:mode]
    when "sso_only" then sso_only = true
    when "password_and_sso" then sso_only = false
    else return head :bad_request
    end

    action = sso_only ? :require_sso : :allow_passwords
    with_sso_settings_proof(action: "sso_policy", target: params[:mode]) do |verified|
      if !current_sso_administrator?
        audit_sso_setting(action, Current.account.public_id, :refused, reason: :administrator_required)
        head :forbidden
      elsif !verified
        audit_sso_setting(action, Current.account.public_id, :refused, reason: :verification_required)
        redirect_to admin_sso_providers_path, alert: t("sso.verify"), status: :see_other
      elsif SsoProvider.set_policy(Current.account, sso_only: sso_only)
        audit_sso_setting(action, Current.account.public_id, :saved)
        redirect_to admin_sso_providers_path, notice: t("sso.saved"), status: :see_other
      else
        audit_sso_setting(action, Current.account.public_id, :refused, reason: Current.account.errors.first.type)
        redirect_to admin_sso_providers_path, alert: Current.account.errors.full_messages.to_sentence, status: :see_other
      end
    end
  end
end
