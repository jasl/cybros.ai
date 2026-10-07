require "digest"
require "openssl"
require "securerandom"
require "uri"

module Rho
  # Human login owns browser sessions; the daemon's Agent and Runner remain
  # separate runtime lineages. Neither a public page nor the CLI's local
  # announcement bearer can obtain a Human Platform credential.
  class OAuthLogin
    TRANSACTION_TTL = 900
    MAX_PENDING = 32
    BEARER_PREFIX = "rho-browser-v1-".freeze
    BEARER = /\Arho-browser-v1-[A-Za-z0-9_-]{43}\z/
    METHODS = %w[GET POST PUT PATCH DELETE].freeze
    REQUEST_HEADERS = %w[if-match if-none-match idempotency-key].freeze
    RESPONSE_HEADERS = %w[content-type retry-after location etag].freeze

    Transaction = Struct.new(:state, :secret_digest, :verifier, :redirect_uri, :plan,
      :deadline, :authorization, :interval, :next_poll_at, keyword_init: true) do
      def connection_mode = plan.request == :login ? "login" : "connect"
    end
    Session = Data.define(:oauth, :user, :agent_public_id)

    # Metadata and its rotating credential publish atomically in one private
    # file, through the same store contract used by Agent credentials.
    class SessionStore
      attr_reader :file, :user, :agent_public_id

      def initialize(file:, user:, agent_public_id:)
        @file = file
        @user = user
        @agent_public_id = agent_public_id
      end

      def read = @file.read&.fetch("credentials")
      def write(document) = @file.write("user" => @user.to_h.transform_keys(&:to_s),
        "agent_public_id" => @agent_public_id, "credentials" => document)
      def delete = @file.delete
      def description = @file.description
      def with_lock(&block) = @file.with_lock(&block)
    end

    def initialize(home:, config:, endpoint:, wire:, ceremony:, clock: -> { Time.now },
      display_name: Rho.default_display_name, authority: nil, operator_bearer: nil, operator_credential: nil)
      @home, @config, @endpoint, @wire = home, config, endpoint, wire
      @ceremony, @clock, @display_name = ceremony, clock, display_name
      @authority = authority
      @operator_bearer, @operator_credential = operator_bearer, operator_credential
      @transactions = {}
      @sessions = {}
      @completion_lock = Mutex.new
      @completing = false
    end

    def register(api)
      api.register_route("GET", "/auth/status", auth: :none) { |request, _ctx| status(request) }
      api.register_route("POST", "/auth/start", auth: :none) { |request, _ctx| start(request) }
      api.register_route("POST", "/auth/complete", auth: :none) { |request, _ctx| complete(request) }
      api.register_route("POST", "/auth/device/start", auth: :none) { |request, _ctx| start_device(request) }
      api.register_route("POST", "/auth/device/poll", auth: :none) { |request, _ctx| poll_device(request) }
      api.register_route("POST", "/auth/logout", auth: :none) { |request, _ctx| logout(request) }
      api.register_route("POST", "/nexus/request") { |request, _ctx| platform_request(request) }
    end

    def authorized?(request)
      !verified_session(request).nil?
    rescue CybrosAgent::Api::Unauthorized, CybrosAgent::Credentials::PlaneUnavailable,
      CybrosAgent::DeviceFlow::AuthorizationLostError
      false
    end

    def status(request)
      session, profile = verified_session(request)
      human = session && session.user.to_h.merge(role: profile.member.role)
      [200, { authenticated: !session.nil?, human: human, nexus_url: public_nexus_url,
        flows: %w[authorization_code device_code] }.compact]
    rescue CybrosAgent::Api::Unauthorized, CybrosAgent::Credentials::PlaneUnavailable,
      CybrosAgent::DeviceFlow::AuthorizationLostError
      [200, { authenticated: false, nexus_url: public_nexus_url, flows: %w[authorization_code device_code] }]
    end

    def start(request)
      json_body(request)
      plan = @ceremony.login_plan
      return plan if plan in Daemon::Refusal

      transaction, secret = new_transaction(plan)
      url = authority.authorization_url(redirect_uri: transaction.redirect_uri, state: transaction.state,
        code_challenge: pkce(transaction.verifier), claims: claims(transaction.plan.request), connection_mode: transaction.connection_mode)
      [200, { authorization_url: url, state: transaction.state, login_secret: secret }]
    rescue CybrosAgent::Error, Rho::Error => error
      refusal(error)
    end

    def complete(request)
      body = json_body(request)
      transaction = transaction_for(body)
      return invalid_transaction if transaction.nil? || transaction.authorization

      complete_transaction(transaction) do
        authority.exchange_code(code: body.fetch("code").to_s, redirect_uri: transaction.redirect_uri,
          code_verifier: transaction.verifier)
      end
    rescue KeyError
      invalid_transaction
    rescue CybrosAgent::Error, Rho::Error => error
      refusal(error)
    end

    def start_device(request)
      json_body(request)
      plan = @ceremony.login_plan
      return plan if plan in Daemon::Refusal

      transaction, secret = new_transaction(plan, callback: false)
      authorization = authority.request_device_authorization(claims: claims(transaction.plan.request), connection_mode: transaction.connection_mode)
      transaction.authorization = authorization
      transaction.interval = authorization.interval
      transaction.next_poll_at = @clock.call
      [200, { phase: "pending", state: transaction.state, login_secret: secret,
        user_code: authorization.user_code, verification_uri: authorization.verification_uri,
        verification_uri_complete: authorization.verification_uri_complete,
        interval: authorization.interval, expires_in: authorization.expires_in }]
    rescue CybrosAgent::ApplicationOAuth::InitializationRequired => error
      @transactions.delete(transaction.state) if transaction
      Daemon::Refusal.new(status: 409, code: "initialization_required", message: error.message,
        extra: { initialization_uri: error.initialization_uri })
    rescue CybrosAgent::Error, Rho::Error => error
      @transactions.delete(transaction.state) if transaction
      refusal(error)
    end

    def poll_device(request)
      transaction = transaction_for(json_body(request))
      return invalid_transaction unless transaction&.authorization
      if @clock.call < transaction.next_poll_at
        return [200, { phase: "pending", interval: transaction.interval }]
      end

      complete_transaction(transaction, polling: true) do
        outcome = authority.poll(transaction.authorization)
        case outcome
        in CybrosAgent::DeviceFlow::Pending
          nil
        in CybrosAgent::DeviceFlow::SlowDown
          transaction.interval += CybrosAgent::DeviceFlow::Client::SLOW_DOWN_STEP
          nil
        in CybrosAgent::DeviceFlow::Throttled
          transaction.interval = [transaction.interval, outcome.retry_after].max
          nil
        else
          outcome
        end
      end
    rescue CybrosAgent::Error, Rho::Error => error
      refusal(error)
    end

    def logout(request)
      json_body(request)
      token = bearer(request)
      session = session_for(token)
      return [200, { logged_out: true }] if session.nil?

      session.oauth.revoke
      @sessions.delete(digest(token))
      [200, { logged_out: true }]
    rescue CybrosAgent::Error, Rho::Error => error
      refusal(error)
    end

    # Only the requesting browser's Human credential is forwarded. Nexus
    # decides personal versus administrator authority from its current User.
    def platform_request(request)
      token = bearer(request)
      credential = if @operator_bearer && OpenSSL.secure_compare(token, @operator_bearer)
        @operator_credential.call
      elsif (session = session_for(token))
        session.oauth.platform_credential
      end
      return Daemon::Refusal.unauthorized if credential.nil?

      body = json_body(request)
      path = body.fetch("path").to_s
      method = body.fetch("method", "GET").to_s.upcase
      uri = URI.parse(path)
      decoded_path = URI::DEFAULT_PARSER.unescape(uri.path)
      unless METHODS.include?(method) && path.start_with?("/api/v1/") &&
          uri.relative? && !uri.host && !uri.fragment && decoded_path.start_with?("/api/v1/") &&
          (decoded_path.split("/") & %w[. ..]).empty? && !decoded_path.include?("\\")
        return Daemon::Refusal.malformed("Name a Nexus /api/v1 resource and HTTP method")
      end
      headers = body.fetch("headers", {}).to_h.transform_keys { |key| key.to_s.downcase }.slice(*REQUEST_HEADERS)
      timeout = Float(body.fetch("timeout", CybrosAgent::Api::BaseClient::DEFAULT_REQUEST_TIMEOUT))
      unless timeout.finite? && timeout.positive? && timeout <= CybrosAgent::DeviceFlow::Client::DEFAULT_REQUEST_TIMEOUT
        return Daemon::Refusal.malformed("The Nexus request timeout must be between 0 and 120 seconds")
      end

      response = transport.call(path, method: method.downcase.to_sym,
        credential: credential, body: body["body"], headers: headers, timeout: timeout)
      response_headers = RESPONSE_HEADERS.to_h { |name| [name, response.headers[name]] }.compact
      [200, { status: response.status, body: response.body, headers: response_headers }]
    rescue KeyError, TypeError, ArgumentError, URI::InvalidURIError
      Daemon::Refusal.malformed("Name a Nexus /api/v1 resource and HTTP method")
    rescue CybrosAgent::Credentials::PlaneUnavailable, CybrosAgent::DeviceFlow::AuthorizationLostError
      Daemon::Refusal.unauthorized
    end

    private

      # Even an empty public login POST must require a preflight. Otherwise
      # an unrelated page could fill the bounded transaction table with forms.
      def json_body(request)
        type = Array(request.headers["content-type"]).first.to_s.split(";").first.to_s.strip
        unless type == ControlServer::JSON_TYPE
          raise ControlServer::MalformedBody, "the request body must be sent as #{ControlServer::JSON_TYPE}"
        end
        ControlServer.json_body(request)
      end

      def authority
        @authority || CybrosAgent::ApplicationOAuth::Client.new(base_url: @home.base_url,
          public_url: public_nexus_url, transport: transport)
      end

      def transport
        @wire.api_transport || (@transport ||= CybrosAgent::HttpTransport.new(base_url: @home.base_url))
      end

      def public_nexus_url = @config.nexus_public_url || @home.base_url

      def redirect_uri
        url = @config.public_url
        if url.nil?
          endpoint = URI.parse(@endpoint.call)
          unless %w[127.0.0.1 localhost ::1].include?(endpoint.hostname)
            raise ConfigurationError, "Set RHO_PUBLIC_URL to this rho's browser address before signing in"
          end
          url = endpoint.to_s
        end
        "#{url}/auth/callback"
      end

      def claims(request)
        runner = { registration_identifier: "#{@config.mode == "runner" ? Rho::STANDALONE_REGISTRATION_IDENTIFIER : Rho::REGISTRATION_IDENTIFIER}.#{@home.instance_id}",
          runner_display_name: @display_name }
        return runner.merge(executor_kind: "runner") if request == :runner || @config.mode == "runner"

        agent = { agent_identifier: "#{Rho::AGENT_IDENTIFIER}.#{@home.instance_id}",
          agent_display_name: @display_name, executor_display_name: @display_name }
        request == :combined || (request == :login && @config.mode == "full") ? agent.merge(runner) : agent
      end

      def new_transaction(plan, callback: true)
        now = @clock.call
        @transactions.delete_if { |_state, transaction| transaction.deadline <= now }
        raise ConnectionError, "Too many pending logins; finish an existing login or wait a few minutes" if @transactions.size >= MAX_PENDING

        secret = SecureRandom.urlsafe_base64(32)
        transaction = Transaction.new(state: SecureRandom.urlsafe_base64(32), secret_digest: digest(secret),
          verifier: SecureRandom.urlsafe_base64(48), redirect_uri: (redirect_uri if callback),
          plan: plan, deadline: now + TRANSACTION_TTL)
        @transactions[transaction.state] = transaction
        [transaction, secret]
      end

      def transaction_for(body)
        transaction = @transactions[body["state"].to_s]
        return nil if transaction.nil? || transaction.deadline <= @clock.call
        return nil unless OpenSSL.secure_compare(transaction.secret_digest, digest(body["login_secret"].to_s))

        transaction
      end

      def complete_transaction(transaction, polling: false)
        claimed = @completion_lock.synchronize do
          next false if @completing

          @completing = true
        end
        return Daemon::Refusal.new(status: 409, code: "login_in_progress", message: "Another login is completing") unless claimed

        # Match the existing credential owner's wire-and-persist boundary:
        # stop cannot split a successful token exchange from private storage.
        Thread.handle_interrupt(Object => :never) do
          credentials = @ceremony.complete_login(transaction.plan) do
            Thread.handle_interrupt(Object => :on_blocking) { yield }
          end
          if credentials in Daemon::Refusal
            @transactions.delete(transaction.state)
            return credentials
          end
          if credentials.nil? && polling
            transaction.next_poll_at = @clock.call + transaction.interval
            return [200, { phase: "pending", interval: transaction.interval }]
          end
          @transactions.delete(transaction.state)
          token = issue_session(credentials)
          [200, { phase: "active", bearer: token }]
        end
      rescue CybrosAgent::DeviceFlow::ServerError, CybrosAgent::TransportError
        @transactions.delete(transaction.state) unless polling
        raise
      rescue StandardError
        @transactions.delete(transaction.state)
        raise
      ensure
        @completion_lock.synchronize { @completing = false } if claimed
      end

      def issue_session(credentials)
        token = "#{BEARER_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
        store = SessionStore.new(file: session_file(token), user: credentials.user, agent_public_id: credentials.agent_public_id)
        oauth = CybrosAgent::Credentials::OAuth.issue(credentials: credentials, authority: authority,
          store: store, clock: @clock)
        @sessions[digest(token)] = Session.new(oauth: oauth, user: credentials.user, agent_public_id: credentials.agent_public_id)
        token
      end

      def session_for(token)
        return nil unless BEARER.match?(token)

        key = digest(token)
        return @sessions[key] if @sessions.key?(key)

        file = session_file(token)
        document = file.read
        return nil if document.nil?

        user = CybrosAgent::ApplicationOAuth::User.new(**document.fetch("user").transform_keys(&:to_sym))
        store = SessionStore.new(file: file, user: user, agent_public_id: document["agent_public_id"])
        oauth = CybrosAgent::Credentials::OAuth.load(authority: authority, store: store, clock: @clock)
        @sessions[key] = Session.new(oauth: oauth, user: user, agent_public_id: store.agent_public_id)
      end

      def verified_session(request)
        session = session_for(bearer(request))
        return nil if session.nil?

        profile = CybrosAgent::PlatformClient.new(base_url: @home.base_url,
          credential_provider: session.oauth.method(:platform_credential).to_proc, transport: transport).profile.fetch
        return nil unless profile.member.public_id == session.user.public_id && profile.member.kind == "human"

        [session, profile]
      end

      def bearer(request) = Array(request.headers["authorization"]).first.to_s[/\ABearer (.+)\z/, 1].to_s
      def digest(value) = Digest::SHA256.hexdigest(value)
      def pkce(value) = [Digest::SHA256.digest(value)].pack("m0").tr("+/", "-_").delete("=")
      def session_file(token) = StateFile.new(File.join(@home.browser_sessions_root, "#{digest(token)}.json"))

      def invalid_transaction
        Daemon::Refusal.new(status: 401, code: "login_expired", message: "This login expired or belongs to another browser; sign in again")
      end

      def refusal(error)
        return Daemon::Refusal.malformed(error.message) if error in ControlServer::MalformedBody

        code = "login_failed"
        code = error.code || code if error in CybrosAgent::Error
        code = error.oauth_error || code if error in CybrosAgent::DeviceFlow::Error
        Daemon::Refusal.new(status: 502, code: code, message: CybrosAgent::Redaction.call(error.message))
      end
  end
end
