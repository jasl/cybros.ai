require "mcp"

module Rho
  module Mcp
    module Oauth
      # ONE PROVIDER CLASS, TWO INTERACTIONS — the gem's `OAuth::Provider` with rho-mcp's storage and the
      # references' client metadata (claude-code's set; codex's
      # `client_name`): a PUBLIC client, both loopback redirect forms
      # registered (the portless one for an AS that honours RFC 8252 §7.3,
      # the live one the gem requires in the list), no fabricated
      # `client_uri`, no `software_*`; `application_type` the gem infers.
      #
      # THE DAEMON'S (`headless`) is attached only when the storage holds
      # tokens: its validator answers false and RECORDS what it refused —
      # the request as data (`refusal`), and on a STEP-UP the union as the
      # store's `pending_scope` — so a daemon that reaches it has read the
      # discovery documents, registered nothing, browsed nothing, and the
      # connection classifies the refusal by the store's state. Its two
      # handlers raise the gem's own refusal (a belt; the validator refuses
      # first). THE CLI'S (`interactive`) prints the consent line before
      # anything is registered — keeping the issuer it names (`issuer`)
      # for the verb's `iss` comparison — prints the URL FIRST and then
      # tries the browser: a launcher that did not start (a missing
      # opener, a failed spawn, none on this host) is ONE more line saying
      # so, never fatal, and the wait on the loopback listener goes on —
      # under `--no-browser` nothing is launched and a pasted line is
      # waited on too.
      class Provider < MCP::Client::OAuth::Provider
        PORTLESS_REDIRECT_URI = "http://127.0.0.1/callback".freeze
        CLIENT_METADATA = {
          "client_name" => "rho",
          "grant_types" => %w[authorization_code refresh_token],
          "response_types" => %w[code],
          "token_endpoint_auth_method" => "none",
        }.freeze
        BROWSER_FALLBACK = "the browser did not open — open the URL above by hand; rho keeps waiting for the redirect to " \
                           "its loopback callback".freeze

        # The last refused `AuthorizationRequest` (`authorization_server`,
        # `scopes`, `server_url`, `resource`), the daemon's half only.
        attr_reader :refusal
        # The authorization server's `issuer` the consent line named — the
        # RFC 9207 anchor the verb compares a callback's `iss` against —
        # the CLI's half only.
        attr_accessor :issuer

        def self.client_metadata(redirect_uri)
          CLIENT_METADATA.merge("redirect_uris" => [PORTLESS_REDIRECT_URI, redirect_uri].uniq.freeze).freeze
        end

        def self.headless(row:, storage:, authorization_mutex: Mutex.new)
          refuse = lambda do |*|
            raise MCP::Client::OAuth::Flow::AuthorizationRefusedError,
              "mcp server #{row.key} needs a login this process cannot perform; run `rho mcp login #{row.key}`"
          end
          provider = nil
          validator = ->(request) { provider.refuse!(request) }
          provider = new(client_metadata: client_metadata(PORTLESS_REDIRECT_URI), redirect_uri: PORTLESS_REDIRECT_URI,
            redirect_handler: refuse, callback_handler: refuse, storage: storage,
            authorization_request_validator: validator, authorization_mutex: authorization_mutex)
        end

        # `browser` is a callable taking the URL and ANSWERING WHETHER IT
        # STARTED (the launcher), or nil where this host has none; `input`
        # the IO a `--no-browser` paste arrives on. Each line is FLUSHED as
        # it is printed: a piped `$stdout` is block-buffered, and a URL a
        # person must copy (or a harness must read) cannot sit in the
        # buffer for the five-minute wait. The consent line's three
        # members are the authorization server's bytes: printed through
        # `redact` and the one escaper. The authorization URL is the one
        # the PERSON must open: printed through the escaper and the row's
        # VALUE redaction alone (`Redact#secrets_only`) — never the SDK's
        # family pattern, which would mask a random `state` or
        # `code_challenge` that happens to spell `sk-…` and hand the person
        # a URL the authorization server refuses; the browser is handed
        # the URL as it is.
        def self.interactive(row:, storage:, callback:, out:, browser: nil, no_browser: false, input: nil,
          redact: Rho::Runner::Redact.new(row.secrets, live: storage))
          redirect_uri = callback.redirect_uri
          shown = Commands.shown(redact)
          provider = nil
          consent = lambda do |request|
            provider.issuer = request.authorization_server
            say(out, "authorizing with #{shown.call(request.authorization_server)} for scopes " \
                     "#{shown.call(request.scopes.join(" "))} (resource #{shown.call(request.resource)})")
            true
          end
          redirect = lambda do |url|
            say(out, "open this URL to authorize rho: #{Commands.escape(redact.secrets_only(url.to_s))}")
            next if no_browser

            say(out, BROWSER_FALLBACK) unless browser&.call(url.to_s)
          end
          wait = -> { callback.wait(paste: no_browser ? input : nil) }
          provider = new(client_metadata: client_metadata(redirect_uri), redirect_uri: redirect_uri,
            redirect_handler: redirect, callback_handler: wait, storage: storage,
            authorization_request_validator: consent)
        end

        def self.say(out, line)
          out.puts line
          out.flush
        end

        def initialize(authorization_mutex: Mutex.new, **)
          @authorization_mutex = authorization_mutex
          @refusal = nil
          @issuer = nil
          @stepping_up = false
          super(**)
        end

        # A canceled MCP caller may leave its HTTP worker refreshing. The
        # connection shares this lock across providers created on reconnect.
        def synchronize_authorization(&) = @authorization_mutex.synchronize(&)

        # The transport's mark around the gem's 403 step-up entry.
        def step_up
          @stepping_up = true
          yield
        ensure
          @stepping_up = false
        end

        def stepping_up? = @stepping_up

        # The headless validator: record, and on a step-up write the union
        # the gem asked for; answer false.
        def refuse!(request)
          @refusal = request
          storage.record_pending_scope(request.scopes) if stepping_up?
          false
        end
      end
    end
  end
end
