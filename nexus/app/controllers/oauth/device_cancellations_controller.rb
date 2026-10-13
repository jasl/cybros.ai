# POST /oauth/device/grants/:grant_id/cancellation — cancel a
# session-verified connection; no credential is shared.
class OAuth::DeviceCancellationsController < OAuth::BrowserController
  def create
    grant = verified_grant(params[:device_grant_id])
    return redirect_to(oauth_device_path, alert: t("oauth.device.unknown_grant")) if grant.nil?

    result = DeviceAuthorizations::Cancel.call(authorization: grant, connector: Current.user)

    subject = helpers.device_grant_subject(grant)
    case result.outcome
    when :canceled
      redirect_to oauth_device_grant_path(grant), notice: t("oauth.device.canceled", subject: subject)
    when :stale
      redirect_to oauth_device_grant_path(grant),
        alert: t("oauth.device.connection_unavailable", subject: subject)
    when :not_authorized
      redirect_to root_path, alert: t("oauth.device.member_required")
    else
      raise ArgumentError, "unsupported device cancellation outcome: #{result.outcome.inspect}"
    end
  end
end
