# POST /oauth/device/verification: charges the exposure budget once per
# browser-held context. Invalid and unknown codes share one non-oracular
# error — a wrong guess identifies no row to charge.
class OAuth::DeviceVerificationsController < OAuth::BrowserController
  rate_limit to: 10, within: 1.minute,
    by: -> { Current.user.public_id },
    scope: "oauth/device-verification",
    with: -> { redirect_to oauth_device_path, alert: t("oauth.device.rate_limited") }

  def create
    @return_to = return_to_url || oauth_device_path
    authorization = DeviceAuthorization.find_live_by_user_code(params.expect(verification: [:user_code])[:user_code])
    authorization&.materialize_expiry

    if authorization.nil? || !authorization.live?
      render_unknown_code
    elsif verified_grant_recorded?(authorization.public_id)
      # This browser context already verified the grant: return to it without a
      # second exposure charge (refresh/back safety).
      redirect_to oauth_device_grant_path(authorization)
    elsif record_verified_grant(authorization)
      redirect_to oauth_device_grant_path(authorization)
    else
      # Budget exhausted: the code no longer verifies anywhere.
      render_unknown_code
    end
  end

  private

    def render_unknown_code
      @prefilled_code = ""
      flash.now[:alert] = t("oauth.device.unknown_code")
      render "oauth/devices/show", status: :unprocessable_entity
    end
end
