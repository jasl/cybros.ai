require "uri"

module CybrosAgent
  # Application login authorizes a Human and optionally connects their Agent
  # and Runner. Each returned lineage retains its own credential plane and
  # refresh token; refreshing the Human never refreshes the runtime addresses.
  module ApplicationOAuth
    User = Data.define(:public_id, :display_name, :role)

    Credentials = Data.define(:access_token, :refresh_token, :expires_in, :token_type, :user,
      :agent_public_id, :agent, :runner) do
      def member_plane? = false
      def executor_plane? = false
      def platform_plane? = true
      def platform_access_token = access_token
      def executor_access_token = nil

      include Redacted

      def inspect
        redacted(user: user, agent_public_id: agent_public_id,
          hidden: %i[access_token refresh_token agent runner])
      end
    end

    class InitializationRequired < DeviceFlow::Error
      attr_reader :initialization_uri

      def initialize(initialization_uri:)
        @initialization_uri = initialization_uri
        super("Complete Nexus setup before starting device login", oauth_error: "initialization_required")
      end
    end

    # Reuses the first-party OAuth wire, deadline, pacing and single-use refresh
    # rules. The separate result type prevents a Human bearer being installed
    # as an Agent's member credential.
    class Client < DeviceFlow::Client
      CLIENT_ID = "cybros-application".freeze
      SCOPE = "application".freeze

      def initialize(base_url:, public_url: base_url, transport: nil,
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) },
        request_timeout: DEFAULT_REQUEST_TIMEOUT)
        super(base_url: base_url, client_id: CLIENT_ID, transport: transport, clock: clock,
          sleeper: sleeper, request_timeout: request_timeout)
        @public_url = public_url.delete_suffix("/")
        @machine_url = base_url.delete_suffix("/")
      end

      def authorization_url(redirect_uri:, state:, code_challenge:, claims:, connection_mode: "connect")
        params = claims.merge(client_id: CLIENT_ID, scope: SCOPE, response_type: "code",
          redirect_uri: redirect_uri, state: state, code_challenge: code_challenge,
          code_challenge_method: "S256", connection_mode: connection_mode)
        "#{@public_url}/oauth/authorize?#{URI.encode_www_form(params)}"
      end

      def request_authorization(agent_identifier:, agent_display_name:, executor_display_name:,
        runner: nil, connection_mode: "connect")
        claims = { agent_identifier: agent_identifier, agent_display_name: agent_display_name,
          executor_display_name: executor_display_name }
        if runner
          claims.merge!(registration_identifier: runner.fetch(:identifier), runner_display_name: runner.fetch(:display_name))
        end
        request_device_authorization(claims: claims, connection_mode: connection_mode)
      end

      def request_runner_authorization(registration_identifier:, runner_display_name:,
        executor_kind: RUNNER_KIND, connection_mode: "connect")
        request_device_authorization(claims: { registration_identifier: registration_identifier,
          runner_display_name: runner_display_name, executor_kind: executor_kind }, connection_mode: connection_mode)
      end

      def request_device_authorization(claims:, connection_mode: "connect")
        authorization = start_authorization(claims.merge(client_id: CLIENT_ID, scope: SCOPE, connection_mode: connection_mode),
          branch: :application, executor_kind: claims.fetch(:executor_kind, AGENT_APPLICATION_KIND))
        authorization.with(verification_uri: browser_uri(authorization.verification_uri),
          verification_uri_complete: browser_uri(authorization.verification_uri_complete))
      end

      # Authorization codes are single use. An ambiguous send is never retried;
      # the caller starts a fresh login after an interrupted exchange.
      def exchange_code(code:, redirect_uri:, code_verifier:)
        response = post("/oauth/token", { client_id: CLIENT_ID, grant_type: "authorization_code",
          code: code, redirect_uri: redirect_uri, code_verifier: code_verifier }, timeout: @request_timeout)
        raise DeviceFlow::RateLimited.new(retry_after: response.retry_after) if response.status == 429
        raise oauth_failure(response) unless response.status == 200

        credentials(response.body, malformed: DeviceFlow::AuthorizationLostError.new("login response was invalid; sign in again"))
      rescue RequestNotSentError
        raise
      rescue TransportError
        raise DeviceFlow::AuthorizationLostError.new("login exchange outcome unknown; sign in again"), cause: nil
      end

      private

        def browser_uri(value)
          uri = URI.parse(value)
          path = uri.request_uri.delete_prefix(URI.parse(@machine_url).path.delete_suffix("/"))
          "#{@public_url}#{path}"
        end

        def oauth_failure(response)
          if response.status == 409 && oauth_error(response) == "initialization_required"
            raise InitializationRequired.new(initialization_uri: "#{@public_url}/setup")
          end

          super
        end

        def validate_initial_credentials(credentials, branch:)
          unless branch == :application && credentials.platform_plane?
            raise DeviceFlow::AuthorizationLostError.new("login response did not authorize a Human")
          end
        end

        def credentials(body, malformed:)
          body = body.to_h
          unless body.fetch("plane") == "platform" && body.fetch("token_type") == "Bearer" &&
              body.fetch("scope") == SCOPE
            raise malformed
          end
          user = body.fetch("user").to_h
          expires_in = Integer(body.fetch("expires_in"))
          raise ArgumentError unless expires_in.positive?

          Credentials.new(access_token: text(body, "access_token"), refresh_token: text(body, "refresh_token"),
            expires_in: expires_in, token_type: "Bearer",
            user: User.new(public_id: text(user, "public_id"), display_name: text(user, "display_name"), role: text(user, "role")),
            agent_public_id: body["agent_public_id"],
            agent: child_credentials(body["agent"], malformed: malformed),
            runner: child_credentials(body["runner"], malformed: malformed))
        rescue KeyError, NoMethodError, TypeError, ArgumentError
          raise malformed, cause: nil
        end

        def child_credentials(body, malformed:)
          return nil if body.nil?

          connection_credentials(body, malformed: malformed)
        end

        def text(body, key)
          value = body.fetch(key).to_str
          raise ArgumentError if value.empty?

          value
        end
    end
  end
end
