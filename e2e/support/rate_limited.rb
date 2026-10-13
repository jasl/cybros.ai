require "json"

module E2E
  # THE MEMBER API'S OWN CEILING, HONOURED (evals 12a L1). `AgentAPI::V1::BaseController`
  # caps a caller at 120 requests a minute per credential and answers 429
  # with a `Retry-After` header (60) and a `{error: {code: rate_limited}}`
  # body — a product fact, never raised for a lane. A harness read that
  # parsed that body as the document it asked for died on a `KeyError`
  # past ≈ 105 tool tasks and lost the whole trace (exit-long ×3). Here a
  # 429 is slept out for the header's seconds (60 when the header is
  # absent) and the read is tried again, ATTEMPTS times in all; the last
  # refusal is raised with the path, so a lane that is truly over the
  # ceiling says so instead of reading nothing.
  module RateLimited
    ATTEMPTS = 3
    RETRY_AFTER_DEFAULT = 60
    TOO_MANY = "429".freeze

    class Refused < StandardError; end

    module_function

    # `yield` performs the request and answers a `Net::HTTPResponse`-shaped
    # object (`code`, `body`, `[]` for a header); the parsed body comes back.
    # `sleeper` is the wait, injectable so a unit test sleeps nothing.
    def read(path, attempts: ATTEMPTS, sleeper: ->(seconds) { sleep(seconds) })
      attempts.times do |attempt|
        response = yield
        return JSON.parse(response.body) unless response.code.to_s == TOO_MANY

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
