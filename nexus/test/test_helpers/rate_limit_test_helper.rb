module RateLimitTestHelper
  private

    def capture_rate_limit_keys
      keys = []
      subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
        key = payload.fetch(:key)
        keys << key if key.start_with?("rate-limit:")
      end

      ActiveSupport::Notifications.subscribed(subscriber, "cache_increment.active_support") do
        yield
      end
      keys
    end

    # Observe the real callback's key, then exercise its boundary without
    # issuing thousands of identical requests to fill the same counter.
    def prime_caller_rate_limit(count:)
      keys = capture_rate_limit_keys { yield }
      key = keys.grep(/:caller:/).uniq.sole
      Rails.cache.write(key, count, expires_in: AgentAPI::V1::BaseController::RATE_LIMIT_WINDOW)
      key
    end
end
