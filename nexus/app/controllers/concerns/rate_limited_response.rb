module RateLimitedResponse
  private

    def render_rate_limited(retry_after:)
      response.headers["Retry-After"] = retry_after.to_i.to_s
      render_rate_limit_error
    end
end
