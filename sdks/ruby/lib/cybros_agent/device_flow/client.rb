require "json"
require "uri"

module CybrosAgent
  module DeviceFlow
    # The minimum typed device-flow client: start an authorization,
    # await credentials with server-honouring pacing, rotate, and revoke. The
    # transport, clock, and sleeper are injectable so the pacing and deadline
    # rules are provable against a fake transport with no real time.
    class Client
      CLIENT_ID = "cybros-first-party-connector".freeze
      DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code".freeze
      REFRESH_GRANT = "refresh_token".freeze
      # A transient polling failure — a connection failure or an unhandled
      # server failure — backs off before a bounded retry; the deadline still
      # caps everything.
      TRANSIENT_RETRY_DELAY = 5
      # The number of consecutive transient polling failures that may be
      # retried; a handled response resets the count.
      TRANSIENT_RETRY_LIMIT = 3
      # Every slow_down raises the next delay by five seconds (RFC 8628 §3.5;
      # the server persists the raised interval).
      SLOW_DOWN_STEP = 5
      # Ordinary machine requests get a finite, deliberately generous total
      # transport budget. Polling further caps this at the authorization's
      # remaining monotonic lifetime.
      DEFAULT_REQUEST_TIMEOUT = 120
      # The planes a token response may lead with.
      MEMBER_PLANE = "member".freeze
      EXECUTOR_PLANE = "executor_transport".freeze
      PLANES = [MEMBER_PLANE, EXECUTOR_PLANE].freeze
      # The executor kinds a connection names: branch A fixes
      # the agent application's; branch B takes a machine kind, the runner's
      # by default.
      AGENT_APPLICATION_KIND = "agent_application".freeze
      RUNNER_KIND = "runner".freeze

      class MalformedResponse < StandardError; end
      private_constant :MalformedResponse

      # The transport implements CybrosAgent::Response's contract (transport.rb);
      # clock returns monotonic seconds and sleeper waits, so pacing is
      # provable with no real time.
      def initialize(base_url:, transport: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) }, request_timeout: DEFAULT_REQUEST_TIMEOUT)
        unless request_timeout.is_a?(Numeric) && request_timeout.finite? && request_timeout.positive?
          raise ArgumentError, "request_timeout must be finite and positive"
        end

        @transport = transport || HttpTransport.new(base_url: base_url)
        @clock = clock
        @sleeper = sleeper
        @request_timeout = request_timeout
      end

      # Branch A: resolves the connecting human's Agent Profile
      # and its current agent_application delivery address. The branch fixes
      # the address kind: winning Consume creates one when absent or re-pairs a
      # matching non-revoked one.
      #
      # With `runner: { identifier:, display_name: }` the request is the
      # COMBINED shape: the same grant also registers a runner
      # on this machine — private to the Agent Profiles the connecting human
      # manages, its kind fixed `runner` by the door, so no `executor_kind`
      # is sent — and the winning poll carries two lineages (`runner_half`).
      def request_authorization(agent_identifier:, agent_display_name:, executor_display_name:, runner: nil)
        params = {
          client_id: CLIENT_ID,
          agent_identifier: agent_identifier,
          agent_display_name: agent_display_name,
          executor_display_name: executor_display_name,
        }
        if runner
          params = params.merge(
            runner_identifier: runner.fetch(:identifier),
            runner_display_name: runner.fetch(:display_name)
          )
        end
        start_authorization(params, branch: runner ? :combined : :agent, executor_kind: AGENT_APPLICATION_KIND)
      end

      # Branch B: identity-less. A machine resolves no Agent
      # Profile and receives only its transport credential, because its
      # address is not a principal. The product supplies its stable
      # code-level identifier and names its kind: `runner` by
      # default, `tools_provider` for a provider — always sent, one wire
      # shape; a value outside that vocabulary is `invalid_request` at the
      # door, and a re-pair naming the other kind for a live key is
      # invalidated at consume. For a fresh registration, Browser Connect
      # lets an owner or administrator opt into account-wide access;
      # re-pairing a live registration preserves its stored access.
      def request_runner_authorization(runner_identifier:, runner_display_name:, executor_kind: RUNNER_KIND)
        start_authorization(
          {
            client_id: CLIENT_ID,
            runner_identifier: runner_identifier,
            runner_display_name: runner_display_name,
            executor_kind: executor_kind,
          },
          branch: :runner,
          executor_kind: executor_kind
        )
      end

      private def start_authorization(params, branch:, executor_kind:)
        requested_at = now
        response = post("/oauth/device_authorization", params, timeout: @request_timeout)
        raise RateLimited.new(retry_after: response.retry_after) if response.status == 429
        raise oauth_failure(response) unless response.status == 200

        authorization(response.body, requested_at: requested_at, branch: branch, executor_kind: executor_kind)
      end
      public :request_authorization, :request_runner_authorization

      # A single poll. Returns Pending, SlowDown, Throttled, or Credentials,
      # or raises a typed DeviceFlow::Error (terminal loss, an integration
      # bug, or a retryable ServerError).
      def poll(authorization)
        timeout = poll_timeout(authorization)
        response = begin
          post("/oauth/token", {
            client_id: CLIENT_ID, grant_type: DEVICE_GRANT, device_code: authorization.device_code,
          }, timeout: timeout)
        rescue TransportError
          check_authorization_deadline(authorization)
          raise
        end
        check_authorization_deadline(authorization)

        if response.status == 200
          result = credentials(
            response.body,
            malformed: AuthorizationLostError.new("token response was invalid; reconnect required")
          )
          validate_initial_credentials(result, branch: authorization.branch)
          return result
        end
        return Throttled.new(retry_after: response.retry_after) if response.status == 429
        raise oauth_failure(response) if response.status >= 500

        case oauth_error(response)
        when "authorization_pending" then Pending.new
        when "slow_down" then SlowDown.new
        else raise oauth_failure(response)
        end
      end

      # Poll until credentials arrive or a terminal condition is reached,
      # never faster than the current interval and never past the deadline.
      # slow_down lengthens the next delay. Connection failures and unhandled
      # server failures (5xx, outside the OAuth vocabulary) share one bounded
      # consecutive-failure budget; a handled response resets it.
      def await_credentials(authorization)
        delay = authorization.interval
        transient_failures = 0

        loop do
          check_authorization_deadline(authorization)

          begin
            outcome = poll(authorization)
            transient_failures = 0
          rescue TransportError, ServerError
            transient_failures += 1
            raise if transient_failures > TRANSIENT_RETRY_LIMIT

            sleep_within_deadline(authorization, TRANSIENT_RETRY_DELAY)
            check_authorization_deadline(authorization)

            outcome = Pending.new
          end

          next_delay = delay
          case outcome
          when Credentials then return outcome
          when SlowDown
            delay += SLOW_DOWN_STEP
            next_delay = delay
          when Throttled
            next_delay = [delay, outcome.retry_after].max
          else nil # Pending: wait the current delay unchanged.
          end

          sleep_within_deadline(authorization, next_delay)
        end
      end

      # First-party extension: cancel the exact short-lived authorization the
      # caller owns. A canceled return is safe-to-kill; a consumed return means
      # Consume won the server row lock, so the caller must let poll finish and
      # adopt its credential bundle. Every other response raises and is
      # therefore unknown, never safe.
      def cancel_authorization(authorization)
        response = post(
          "/oauth/device_authorization/cancellation",
          { client_id: CLIENT_ID, device_code: authorization.device_code },
          timeout: @request_timeout
        )
        return :canceled if response.status == 200
        if response.status == 409 && oauth_error(response) == "too_late"
          return :consumed
        end
        raise RateLimited.new(retry_after: response.retry_after) if response.status == 429

        raise oauth_failure(response)
      end

      # Rotation reissues whatever planes the connection still has authority
      # for, and the response says which — a host holding only a persisted
      # refresh secret needs no other context.
      def rotate(refresh_token:)
        params = { client_id: CLIENT_ID, grant_type: REFRESH_GRANT, refresh_token: refresh_token }
        response = post("/oauth/token", params, timeout: @request_timeout)
        raise RateLimited.new(retry_after: response.retry_after) if response.status == 429
        if response.status >= 500
          raise AuthorizationLostError.new("refresh rotation outcome unknown; reconnect required")
        end
        raise DeviceFlow.for_oauth_error(oauth_error(response)) unless response.status == 200

        credentials(
          response.body,
          malformed: AuthorizationLostError.new("refresh rotation response was invalid; reconnect required")
        )
      rescue RequestNotSentError
        raise
      rescue TransportError
        raise AuthorizationLostError.new("refresh rotation outcome unknown; reconnect required")
      end

      # RFC 7009: an accepted revocation always answers 200 with an empty
      # body and never reveals whether the token existed. Anything else is a
      # failure the caller may act on: 429 is retryable throttling, an OAuth
      # error is typed, and a body-less server failure is a retryable
      # ServerError.
      def revoke(token:)
        response = post("/oauth/revoke", { client_id: CLIENT_ID, token: token }, timeout: @request_timeout)
        return nil if response.status == 200
        raise RateLimited.new(retry_after: response.retry_after) if response.status == 429

        raise oauth_failure(response)
      end

      private

      # Machine endpoints speak application/x-www-form-urlencoded and answer JSON.
      def post(path, params, timeout:)
        @transport.call(path, method: :post, form: params, timeout: timeout)
      end

      # The OAuth error vocabulary applies only to handled responses: an
      # unhandled 5xx is a server failure by status alone, even when an
      # intermediary happens to emit a JSON error field.
      def oauth_failure(response)
        return ServerError.new("server failure (status #{response.status})") if response.status >= 500

        DeviceFlow.for_oauth_error(oauth_error(response))
      end

      def authorization(body, requested_at:, branch:, executor_kind:)
        body = response_hash(body)
        expires_in = positive_integer(body, "expires_in")
        raise MalformedResponse if expires_in > Float::MAX

        deadline_monotonic = requested_at + expires_in
        raise MalformedResponse unless deadline_monotonic.finite?

        Authorization.new(
          device_code: nonempty_string(body, "device_code"),
          user_code: nonempty_string(body, "user_code"),
          verification_uri: absolute_http_uri(body, "verification_uri"),
          verification_uri_complete: absolute_http_uri(body, "verification_uri_complete"),
          interval: positive_integer(body, "interval"),
          expires_in: expires_in,
          deadline_monotonic: deadline_monotonic,
          branch: branch,
          executor_kind: executor_kind
        )
      rescue MalformedResponse
        raise ServerError.new("invalid device authorization response"), cause: nil
      end

      def poll_timeout(authorization)
        remaining = authorization.deadline_monotonic - now
        unless remaining.positive?
          raise DeadlineExceeded.new("device authorization deadline passed")
        end

        [@request_timeout, remaining].min
      end

      def check_authorization_deadline(authorization)
        if now >= authorization.deadline_monotonic
          raise DeadlineExceeded.new("device authorization deadline passed")
        end
      end

      def sleep_within_deadline(authorization, delay)
        remaining = authorization.deadline_monotonic - now
        @sleeper.call([delay, remaining].min) if remaining.positive?
      end

      # The response names the plane of its leading `access_token`, and
      # `executor_access_token` accompanies it only when a bundle carries both
      # (docs/oauth/device-flow.md, Success shape). The typed result sorts
      # them by plane so no caller has to infer which is which — and a
      # transport-led response can never carry a second transport credential,
      # the nested `runner` object of a combined consume included.
      def credentials(body, malformed:)
        body = response_hash(body)
        token_type = nonempty_string(body, "token_type")
        raise MalformedResponse unless token_type == "Bearer"

        leading = nonempty_string(body, "access_token")
        plane = nonempty_string(body, "plane")
        raise MalformedResponse unless PLANES.include?(plane)

        accompanying = body["executor_access_token"]
        runner = body["runner"]
        transport_led = plane == EXECUTOR_PLANE
        raise MalformedResponse if transport_led && !(accompanying.nil? && runner.nil?)
        unless accompanying.nil?
          raise MalformedResponse unless accompanying.is_a?(String) && !accompanying.empty?
        end
        runner = response_hash(runner) unless runner.nil?

        Credentials.new(
          access_token: (leading unless transport_led),
          executor_access_token: transport_led ? leading : accompanying,
          refresh_token: nonempty_string(body, "refresh_token"),
          token_type: token_type,
          expires_in: positive_integer(body, "expires_in"),
          runner_access_token: (nonempty_string(runner, "access_token") if runner),
          runner_refresh_token: (nonempty_string(runner, "refresh_token") if runner)
        )
      rescue MalformedResponse
        raise malformed, cause: nil
      end

      # Initial Consume has a stronger branch contract than later rotation:
      # Agent connects with both planes and no runner half; Runner connects
      # with transport only; the combined shape connects with all three.
      # Rotation intentionally keeps using the generic parser because member
      # authority may disappear while transport authority survives.
      def validate_initial_credentials(credentials, branch:)
        valid = case branch
        when :agent
          credentials.member_plane? && credentials.executor_plane? && !credentials.runner_plane?
        when :runner
          !credentials.member_plane? && credentials.executor_plane?
        when :combined
          credentials.member_plane? && credentials.executor_plane? && credentials.runner_plane?
        else
          false
        end
        unless valid
          raise AuthorizationLostError.new(
            "token response did not match authorization branch; reconnect required"
          )
        end
      end

      def response_hash(body)
        raise MalformedResponse unless body.is_a?(Hash)

        body
      end

      def nonempty_string(body, field)
        value = body[field]
        raise MalformedResponse unless value.is_a?(String) && !value.empty?

        value
      end

      def positive_integer(body, field)
        value = body[field]
        raise MalformedResponse unless value.is_a?(Integer) && value.positive?

        value
      end

      def absolute_http_uri(body, field)
        value = nonempty_string(body, field)
        uri = URI.parse(value)
        unless uri.is_a?(URI::HTTP) && uri.host
          raise MalformedResponse
        end

        value
      rescue URI::Error
        raise MalformedResponse
      end

      def oauth_error(response)
        response.body.is_a?(Hash) ? response.body["error"] : nil
      end

      def now
        @clock.call
      end
    end
  end
end
