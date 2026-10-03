# The cookie-only device ceremony: any active human member may connect a
# program to their resolved Agent profile; agent principals and every bearer
# are excluded. Never cached, never leaking grant context via referrer.
class OAuth::BrowserController < ApplicationController
  include CapabilityPageResponse
  include BooleanParameter

  VERIFIED_GRANT_CONTEXT_COOKIE_NAME = :verified_device_grant_context
  VERIFIED_GRANT_CONTEXT_COOKIE_TTL =
    DeviceAuthorization::TTL + DeviceAuthorization::TERMINAL_RETENTION

  before_action :require_human_member
  before_action :ensure_verified_grant_context

  private

    def require_human_member
      unless Current.user&.active_human_member?
        redirect_to root_path, alert: t("oauth.device.member_required")
      end
    end

    # One encrypted HTTP-only cookie identifies the browser context; bounded
    # server-side rows record which grants it verified. The cookie survives a
    # Session reset so reauthentication preserves the ceremony.
    def record_verified_grant(authorization)
      DeviceGrantVerification.record(
        authorization: authorization,
        browser_context_digest: verified_grant_context_digest
      )
    end

    def verified_grant_recorded?(public_id)
      verified_grant(public_id).present?
    end

    def verified_grant(param)
      public_id = param.to_s
      Current.account.device_authorizations
        .joins(:device_grant_verifications)
        .find_by(
          public_id: public_id,
          device_grant_verifications: {
            browser_context_digest: verified_grant_context_digest,
          }
        )
    end

    def ensure_verified_grant_context
      raw = cookies.encrypted[VERIFIED_GRANT_CONTEXT_COOKIE_NAME]
      if DeviceGrantVerification.digest_browser_context(raw).nil?
        raw = DeviceGrantVerification.browser_context_for(session: Current.session)
      end
      @verified_grant_context = raw

      cookies.encrypted[VERIFIED_GRANT_CONTEXT_COOKIE_NAME] = {
        value: raw,
        expires: VERIFIED_GRANT_CONTEXT_COOKIE_TTL.from_now,
        httponly: true,
        secure: request.ssl?,
        same_site: :lax,
      }
    end

    def verified_grant_context_digest
      @verified_grant_context_digest ||=
        DeviceGrantVerification.digest_browser_context(@verified_grant_context)
    end
end
