require "json"

module E2E
  # Fixture preparation and diagnostic reads respect the server's Retry-After.
  # Only explicit 429 refusals are retried; ambiguous transport failures and
  # other responses remain the caller's responsibility.
  module RateLimited
    ATTEMPTS = 3
    RETRY_AFTER_DEFAULT = 60
    TOO_MANY = "429".freeze

    class Refused < StandardError; end

    module_function

    def read(path, **options, &block)
      JSON.parse(request(path, **options, &block).body)
    end

    # Returns the Net::HTTPResponse-shaped answer so status assertions survive.
    def request(path, attempts: ATTEMPTS, sleeper: ->(seconds) { sleep(seconds) })
      attempts.times do |attempt|
        response = yield
        return response unless response.code.to_s == TOO_MANY

        wait = retry_after(response)
        raise Refused, "#{path}: 429 rate_limited #{attempts} times (retry_after #{wait})" if attempt == attempts - 1

        warn "#{path}: 429 rate_limited, sleeping #{wait} s (attempt #{attempt + 1}/#{attempts})"
        sleeper.call(wait)
      end
    end

    # The header's seconds, else the kernel's window.
    def retry_after(response)
      Integer(response["Retry-After"].to_s)
    rescue ArgumentError, TypeError
      RETRY_AFTER_DEFAULT
    end
  end
end
