# The OAuth machine endpoints: form in, JSON out, no cookies or CSRF state;
# every response non-cacheable and errors in the top-level OAuth envelope.
class OAuth::MachineController < ActionController::API
  include RateLimitedResponse
  include OAuthParameters

  before_action :set_no_store

  rescue_from ActionDispatch::Http::Parameters::ParseError, with: -> { render_oauth_error(:invalid_request) }

  private

    # `Pragma` is RFC 6749 §5.1's own ask on the token endpoint.
    def set_no_store
      no_store
      response.headers["Pragma"] = "no-cache"
    end

    def render_oauth_error(code, status: :bad_request)
      render json: { error: code.to_s }, status: status
    end

    def render_rate_limit_error
      render_oauth_error(:temporarily_unavailable, status: :too_many_requests)
    end
end
