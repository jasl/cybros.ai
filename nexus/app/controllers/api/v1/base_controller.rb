# Platform-family base: an api-kind Session bearer, a platform-plane
# AccessToken, or the browser cookie for safe requests only (no CSRF
# protection here). Member-plane tokens never authenticate here.
class API::V1::BaseController < ActionController::API
  # No implicit root wrapping (predecessor parity, item-6 review).
  wrap_parameters false

  include ActionController::Cookies
  include ActionController::HttpAuthentication::Token::ControllerMethods
  include APIErrors

  before_action :require_platform_authentication

  # The API family opts individual actions out of authentication with the
  # same explicit-allowlist discipline as the web console.
  def self.allow_unauthenticated_access(only:)
    skip_before_action :require_platform_authentication, only: only
  end

  private

    def require_platform_authentication
      unless platform_principal?
        render_unauthorized
      end
    end

    def platform_principal?
      resume_platform_principal
      Current.session.present? || Current.access_token.present?
    end

    def resume_platform_principal
      if Current.session.nil? && Current.access_token.nil?
        if request.authorization
          bearer_principal
        elsif request.get? || request.head?
          session = Session.find_usable(cookies.signed[:session_id])
          # The forced-change wall follows the principal across transports:
          # a temporary-password identity reaches nothing on the platform
          # family either, mirroring the api-login rejection.
          unless session&.identity&.password_change_required?
            Current.session = session
          end
        end
      end
    end

    def bearer_principal
      authenticate_with_http_token do |raw, _options|
        if (session = Session.authenticate_api_token(raw))
          Current.session = session
        elsif (token = AccessToken.authenticate_platform_token(raw))
          # Platform reach requires the mint-frozen platform plane and the
          # live admin role: the plane alone never outlives a demotion.
          Current.access_token = token if token.user.admin?
        end
      end
    end
end
