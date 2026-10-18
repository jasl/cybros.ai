require "base64"
require "digest"
require "json"
require "mcp"
require "rack"
require "securerandom"
require "uri"

module McpTest
  # THE MOCK AUTHORIZATION SERVER + RESOURCE SERVER: ONE Rack app on ONE loopback port serving the RS — `/mcp`
  # (the gem's `StreamableHTTPTransport` behind a bearer check: a 401
  # with `WWW-Authenticate: Bearer resource_metadata="…", scope="fx:read"`,
  # a 403 `insufficient_scope` while `require_scope` stands), PRM at
  # `/.well-known/oauth-protected-resource/mcp` — and the AS (issuer
  # `<base>/oauth`; metadata at `/.well-known/oauth-authorization-server/
  # oauth`; `/oauth/register`, `/oauth/authorize` auto-consent with `iss`,
  # `/oauth/token` with PKCE verification and refresh rotation). The
  # shape is the specification's own, never a vendor's — the 2026-07-28
  # pages `basic/authorization/index.mdx` (the flow, PKCE, `iss`, the
  # resource parameter), `authorization-server-discovery.mdx` (PRM and
  # AS metadata), `client-registration.mdx` (dynamic registration; no
  # CIMD advertised) and `security-considerations.mdx`. The AS honours
  # what it was told: an `authorize` names a client it registered (or the
  # by-hand `PRE_REGISTERED` one) with a `redirect_uri` on that client's
  # registered list (RFC 8252 §7.3: the portless loopback entry covers any
  # port), and the token endpoint binds a code and a refresh token to the
  # `client_id` that earned them. The switches: `revoke`, `token_outage`,
  # `slow_token` (the token endpoint holds for a beat, so two calls meeting
  # one expiry are in flight TOGETHER and only a serialized row spends one
  # refresh), `require_scope`, `deny` (on, or the `error_description` the
  # AS answers with, so a pin can hand the verb a terminal-title escape),
  # `tamper_state`, `tamper_iss`, `optional` (THE OPTIONAL-AUTHORIZATION
  # SHAPE: `/mcp` answers an anonymous POST through the transport — the
  # spec's "authorization is OPTIONAL" — while the PRM stays published and
  # an anonymous GET is a 405 carrying the same `WWW-Authenticate`; a
  # token, when sent, is still checked), `no_prm` (the well-known answers
  # 404: a server that publishes nothing); the door `expire` (every live
  # access token expired at once — a property, never a clock); the
  # counters (`issued`; `anonymous` counts the calls the door let through
  # untokened). Its base URL is the request's own authority, so a port of
  # the OS's choosing needs no setter. The e2e fixture's `oauth` entry
  # mounts this same app under puma (one implementation; risk 14).
  # `challenge:` picks the RS's 401 flavour: `:oauth` (the metadata
  # named), `:bearer` (a bare Bearer), `:header` (no Bearer challenge).
  class OauthFixture
    PRM_PATH = "/.well-known/oauth-protected-resource/mcp".freeze
    AS_METADATA_PATH = "/.well-known/oauth-authorization-server/oauth".freeze
    SCOPES = %w[fx:read fx:write].freeze
    CHALLENGE_SCOPE = "fx:read".freeze
    EXPIRES_IN = 3600
    SLOW_TOKEN_SECONDS = 0.4
    PRE_REGISTERED = "rho-at-acme".freeze
    PORTLESS_REDIRECT_URI = "http://127.0.0.1/callback".freeze
    DENIED = "the person said no <b>".freeze
    SWITCHES = %r{\A/fixture/(revoke|token_outage|slow_token|require_scope|deny|tamper_state|tamper_iss|optional|no_prm)\z}

    attr_reader :counters, :records, :switches, :issued_tokens

    def initialize(server:, challenge: :oauth)
      @transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)
      @challenge = challenge
      @lock = Mutex.new
      @clients = {}
      @codes = {}
      @tokens = {}
      @refresh_tokens = {}
      @issued_tokens = []
      @counters = Hash.new(0)
      @counters[:token_resource_seen] = false
      @records = { authorize: nil, registration: nil, authorization_headers: [], token_requests: [] }
      @switches = { revoke: false, token_outage: false, slow_token: false, require_scope: nil, deny: false,
                    tamper_state: false, tamper_iss: false, optional: false, no_prm: false }
    end

    def call(env)
      request = Rack::Request.new(env)
      base = "http://#{request.host_with_port}"
      case [request.request_method, request.path]
      in ["GET", PRM_PATH] then prm(base)
      in ["GET", AS_METADATA_PATH] then as_metadata(base)
      in ["POST", "/oauth/register"] then register(request)
      in ["GET", "/oauth/authorize"] then authorize(request, base)
      in ["POST", "/oauth/token"] then token(request, base)
      in ["GET", "/fixture/issued"] then json(200, issued)
      in ["POST", "/fixture/expire"] then expire
      in ["POST", SWITCHES] then switch(request)
      in [_, "/mcp"] then resource(request, env, base)
      else json(404, { "error" => "not found" })
      end
    end

    # The counters and records the pins read. `token_requests` holds each
    # token post's `grant_type` and `resource` alone — no token value ever
    # enters the record.
    def issued
      { "prm_reads" => @counters[:prm_reads], "metadata_reads" => @counters[:metadata_reads],
        "registrations" => @counters[:registrations], "authorizations" => @counters[:authorizations],
        "refreshes" => @counters[:refreshes], "anonymous" => @counters[:anonymous],
        "token_resource_seen" => @counters[:token_resource_seen],
        "tokens" => @issued_tokens, "authorize" => @records[:authorize], "registration" => @records[:registration],
        "authorization_headers" => @records[:authorization_headers], "token_requests" => @records[:token_requests] }
    end

    private

      def prm(base)
        @counters[:prm_reads] += 1
        return json(404, { "error" => "not found" }) if @switches[:no_prm]

        json(200, { "resource" => "#{base}/mcp", "authorization_servers" => ["#{base}/oauth"], "scopes_supported" => SCOPES })
      end

      def as_metadata(base)
        @counters[:metadata_reads] += 1
        issuer = "#{base}/oauth"
        json(200, { "issuer" => issuer, "authorization_endpoint" => "#{issuer}/authorize", "token_endpoint" => "#{issuer}/token",
                    "registration_endpoint" => "#{issuer}/register", "code_challenge_methods_supported" => ["S256"],
                    "response_types_supported" => ["code"], "grant_types_supported" => %w[authorization_code refresh_token],
                    "token_endpoint_auth_methods_supported" => ["none"], "scopes_supported" => SCOPES,
                    "authorization_response_iss_parameter_supported" => true })
      end

      def register(request)
        body = JSON.parse(request.body.read)
        @counters[:registrations] += 1
        id = "dcr-#{@counters[:registrations]}"
        @lock.synchronize { @clients[id] = body }
        @records[:registration] = body
        json(201, { "client_id" => id, "token_endpoint_auth_method" => "none", "redirect_uris" => body["redirect_uris"] })
      end

      # Auto-consent: the code minted for a known client, an S256 challenge
      # and a redirect_uri the client registered; `state` and `iss` on the
      # redirect, tampered by their switches.
      def authorize(request, base)
        params = request.params
        @records[:authorize] = params
        client_id = params["client_id"]
        redirect = URI.parse(params.fetch("redirect_uri"))
        query = [["state", @switches[:tamper_state] ? "tampered" : params["state"]]]
        if @switches[:deny]
          query << ["error", "access_denied"] << ["error_description", @switches[:deny]]
        elsif !known_client?(client_id) || params["code_challenge_method"] != "S256" ||
              !registered_redirect?(client_id, params.fetch("redirect_uri"))
          query << ["error", "invalid_request"] << ["error_description", "unknown client, challenge or redirect"]
        else
          code = SecureRandom.hex(12)
          @lock.synchronize do
            @codes[code] = { challenge: params["code_challenge"], redirect_uri: params["redirect_uri"],
                             scope: params["scope"] || CHALLENGE_SCOPE, client_id: client_id }
          end
          @counters[:authorizations] += 1
          query << ["code", code]
        end
        query << ["iss", @switches[:tamper_iss] ? "#{base}/other" : "#{base}/oauth"]
        redirect.query = URI.encode_www_form(query)
        [302, { "location" => redirect.to_s, "content-type" => "text/plain" }, ["redirecting"]]
      end

      def token(request, base)
        form = request.POST
        @records[:token_requests] << form.slice("grant_type", "resource")
        sleep(SLOW_TOKEN_SECONDS) if @switches[:slow_token]
        return json(503, { "error" => "temporarily_unavailable" }) if @switches[:token_outage]

        case form["grant_type"]
        when "authorization_code" then exchange_code(form, base)
        when "refresh_token" then refresh(form)
        else json(400, { "error" => "unsupported_grant_type" })
        end
      end

      # The code is single-use and the client's own; the verifier must
      # hash to the challenge; the redirect_uri must be the one authorized.
      def exchange_code(form, base)
        code = @lock.synchronize { @codes.delete(form["code"]) }
        return json(400, { "error" => "invalid_grant" }) if code.nil? || form["client_id"] != code[:client_id]

        digest = Base64.urlsafe_encode64(Digest::SHA256.digest(form["code_verifier"].to_s), padding: false)
        return json(400, { "error" => "invalid_grant", "error_description" => "PKCE" }) unless digest == code[:challenge]
        return json(400, { "error" => "invalid_grant", "error_description" => "redirect_uri" }) unless form["redirect_uri"] == code[:redirect_uri]

        @counters[:token_resource_seen] = true if form["resource"] == "#{base}/mcp"
        json(200, mint(code[:scope], code[:client_id]))
      end

      def refresh(form)
        entry = @lock.synchronize { @refresh_tokens.delete(form["refresh_token"]) }
        return json(400, { "error" => "invalid_grant" }) if entry.nil? || @switches[:revoke] || entry[:client_id] != form["client_id"]

        @counters[:refreshes] += 1
        json(200, mint(entry[:scope], entry[:client_id]))
      end

      # A rotated pair: the previous refresh token is dead the moment a new
      # one is minted (OAuth 2.1's rule for public clients); the refresh
      # token remembers the client that earned it.
      def mint(scope, client_id)
        access = "at-#{SecureRandom.hex(16)}"
        refresh = "rt-#{SecureRandom.hex(16)}"
        @lock.synchronize do
          @tokens[access] = { scope: scope, expires_at: now + EXPIRES_IN }
          @refresh_tokens[refresh] = { scope: scope, client_id: client_id }
          @issued_tokens << access << refresh
        end
        { "access_token" => access, "token_type" => "Bearer", "expires_in" => EXPIRES_IN, "refresh_token" => refresh, "scope" => scope }
      end

      # THE DOOR: every live access token expired at once, so a refresh is
      # observed as a property of the next call, never as a race against a
      # clock. One-shot — nothing to switch back.
      def expire
        expired = @lock.synchronize do
          live = @tokens.count { |_access, token| token[:expires_at] > now }
          @tokens = @tokens.transform_values { |token| token.merge(expires_at: -Float::INFINITY) }
          live
        end
        json(200, { "expired" => expired })
      end

      def resource(request, env, base)
        header = env["HTTP_AUTHORIZATION"].to_s
        return anonymous(request, env, base) if header.empty? && @switches[:optional]

        token = header.delete_prefix("Bearer ")
        granted = @lock.synchronize { @tokens[token] }
        return unauthorized(base) if granted.nil? || granted[:expires_at] < now || @switches[:revoke]
        if (required = @switches[:require_scope]) && !granted[:scope].split.include?(required)
          return [403, { "www-authenticate" => "Bearer error=\"insufficient_scope\", scope=\"#{required}\", " \
                                               "resource_metadata=\"#{base}#{PRM_PATH}\"" }, []]
        end

        @records[:authorization_headers] << header
        @transport.call(env)
      end

      # THE OPTIONAL DOOR: an untokened POST is the transport's to answer
      # (counted); an untokened GET is the 405 a streamable server without a
      # listening stream answers, carrying the challenge as a hint.
      def anonymous(request, env, base)
        if request.get?
          return [405, { "allow" => "POST", "www-authenticate" => challenge_header(base), "content-type" => "text/plain" },
                  ["method not allowed"]]
        end

        @counters[:anonymous] += 1
        @transport.call(env)
      end

      def unauthorized(base)
        [401, { "www-authenticate" => challenge_header(base), "content-type" => "application/json" }, ['{"error":"unauthorized"}']]
      end

      def challenge_header(base)
        case @challenge
        when :oauth then "Bearer resource_metadata=\"#{base}#{PRM_PATH}\", scope=\"#{CHALLENGE_SCOPE}\""
        when :bearer then "Bearer realm=\"fx\""
        else "Basic realm=\"fx\""
        end
      end

      def switch(request)
        name = request.path.delete_prefix("/fixture/").to_sym
        value = request.body.read.to_s.strip
        @switches[name] = case name
        when :require_scope then value.empty? ? nil : value
        when :deny then value == "on" ? DENIED : (value != "off" && value)
        else value != "off"
        end
        json(200, { name.to_s => @switches[name] })
      end

      def known_client?(id) = @lock.synchronize { @clients.key?(id) } || id == PRE_REGISTERED

      # A registered client's redirect_uri is on its list — exactly, or
      # under the portless loopback entry, which RFC 8252 §7.3 reads as
      # any port on 127.0.0.1 with that path; the by-hand client was
      # registered with the loopback shape.
      def registered_redirect?(client_id, redirect_uri)
        uri = URI.parse(redirect_uri)
        return loopback?(uri) if client_id == PRE_REGISTERED

        registered = @lock.synchronize { Array(@clients.dig(client_id, "redirect_uris")) }
        registered.include?(redirect_uri) || (registered.include?(PORTLESS_REDIRECT_URI) && loopback?(uri))
      end

      def loopback?(uri) = uri.host == "127.0.0.1" && uri.path == "/callback"

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def json(status, body)
        [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
      end
  end
end
