require "mcp"

module Rho
  module Mcp
    module Oauth
      # THE VERB: `rho mcp login NAME
      # [--no-browser]` in the CLI process, no daemon needed, three phases
      # each printed as one line. 1. THE CHALLENGE: the probe's own
      # transport (the row's headers, NO provider) connects; a 401 is
      # classified (`Challenge`) and its `resource_metadata` and `scope`
      # kept; "no Bearer challenge" stops with the header sentence; a
      # server that answers WITHOUT a 401 is probed for what it PUBLISHES
      # (`Challenge.published`: the GET's hint, the well-known document
      # path-aware then at the root) — a published authorization server
      # makes it loggable all the same (authorization is optional there;
      # the daemon sends the token on every call once logged in), and only
      # a server with neither ends the verb: nothing to log in to. 2. THE
      # FLOW: the gem's `Flow#run!` on the interactive provider — the ONE
      # explicit scope is the step-up union the daemon recorded, else the
      # challenge's (the spec's MUST), else the gem falls to PRM; the URL
      # is printed, the browser tried (a launcher that did not start is
      # said, never fatal), the gem checks `state` and `iss`, exchanges
      # the code, saves through the storage (`issued_at` stamped), and the
      # verb clears `pending_scope`. A failure's sentence compares the
      # callback's `iss` with the issuer the consent named BEFORE it quotes
      # anything the answer said. 3. THE PROOF: a connect +
      # `tools/list` on the storage's READ-ONLY view — the token proven,
      # nothing refreshed, nothing cleared, the tokens staying stored
      # whatever the proof says. Between the two, the store is marked
      # `optional` when the challenge was a published one (the shape
      # above), so the `auth:` line says it after the verb has gone.
      # Failures are one sentence on stderr and a non-zero exit (the CLI's
      # `abort_with`).
      module Login
        WAIT_SECONDS = Callback::DEFAULT_WAIT_SECONDS
        CLIENT_ID_HINT = "set `oauth.client_id` under the server in settings.json to a client you registered by hand".freeze
        OPTIONAL_CLAUSE = " — authorization is optional here: the server answered anonymously too, and every call carries " \
                          "the token from now on".freeze

        module_function

        # `browser` is the launcher (a callable taking the URL, answering
        # whether it started) or nil; `callback` and `input` are the test
        # seams.
        def call(cli, row, storage, options, browser: nil, input: $stdin, callback: nil)
          out = cli.out
          redact = Rho::Runner::Redact.new(row.secrets, live: storage)
          challenge = harvest_challenge(cli, row, redact) || published_challenge(row)
          if challenge.nil?
            out.puts "#{row.key} answered without asking for authorization and publishes no authorization server — " \
                     "nothing to log in to (an open server, or one your headers already satisfy)"
            return nil
          end
          Commands.refuse(challenge.sentence(row.key)) if challenge.header?

          run_flow(row, storage, challenge, out, redact, browser: browser, no_browser: options[:"no-browser"] == true,
            input: input, callback: callback)
          storage.record_optional(challenge.optional?)
          status = prove(cli, row, storage, redact)
          refresh(cli, row)
          status
        end

        def refresh(cli, row)
          if cli.core.running_daemon.nil?
            cli.out.puts "no daemon running; #{row.key}'s tools will be announced at the next boot"
            return
          end

          result = cli.core.refresh_mcp(row.key)
          failures = result.fetch("failures")
          unless failures.empty?
            Commands.refuse("logged in; daemon refresh failed: #{Commands.escape(failures.map { |failure| failure.fetch("message") }.join("; "))}")
          end
          server = result.fetch("server")
          case server.fetch("state")
          when "connected"
            cli.out.puts "daemon refreshed #{row.key}: #{server.fetch("tools").length} tools announced"
          when "disabled"
            cli.out.puts "#{row.key} remains disabled; run `rho mcp enable #{row.key}` to announce its tools"
          else
            Commands.refuse("logged in; #{row.key} remains #{server.fetch("state")}: #{Commands.escape(server["detail"])}")
          end
        end

        # Phase 1: the classified 401, or nil for a server that answered.
        def harvest_challenge(cli, row, redact)
          connection = Connection.new(row, redact: redact, transport_factory: Rho::Mcp.transport_factory)
          begin
            connection.open!(list: false)
          rescue Unavailable => error
            return connection.challenge if connection.challenge

            Commands.refuse("#{row.key} #{row.launch}  down: #{error.message}")
          end
          connection.close
          nil
        end

        # Phase 1, the optional-authorization shape: what the server that
        # answered publishes, under the row's startup bound.
        def published_challenge(row)
          Challenge.published(url: row.url, headers: row.headers, seconds: row.startup_timeout_ms / 1000.0)
        end

        # Phase 2: the gem's flow on the interactive provider.
        def run_flow(row, storage, challenge, out, redact, browser:, no_browser:, input:, callback:)
          listener = (callback || Callback.new(port: row.oauth&.callback_port, seconds: WAIT_SECONDS)).bind
          provider = Provider.interactive(row: row, storage: storage, callback: listener, out: out, browser: browser,
            no_browser: no_browser, input: input, redact: redact)
          scope = storage.pending_scope || challenge.scope
          begin
            MCP::Client::OAuth::Flow.new(provider: provider).run!(
              server_url: MCP::Client::OAuth::Discovery.canonicalize_url(row.url),
              resource_metadata_url: challenge.resource_metadata, scope: scope
            )
          rescue MCP::Client::OAuth::Flow::AuthorizationError => error
            Commands.refuse(flow_failure(row, listener, provider, error.message, redact))
          ensure
            listener.close
          end
          storage.clear_pending_scope!
        end

        # The verb's sentence is assembled from the listener's record, never
        # the gem's text, where the listener saw the answer. FIRST the
        # issuer: a callback whose `iss` is not the authorization server
        # the consent named is the mismatch alone — its `error` and
        # `error_description` are an impostor's bytes and are not quoted.
        # Then the answer's `error` and `error_description`, the
        # authorization server's bytes, which the gem's text quotes too —
        # one escaper for all.
        def flow_failure(row, listener, provider, message, redact)
          shown = Commands.shown(redact)
          if issuer_mismatch?(listener, provider)
            "#{row.key}'s authorization response named issuer `#{shown.call(listener.iss)}`, not the authorization " \
              "server rho sent you to (`#{shown.call(provider.issuer)}`) — RFC 9207 `iss` mismatch; nothing was exchanged"
          elsif listener.error
            "#{row.key}'s authorization server answered `#{shown.call(listener.error)}`" \
              "#{listener.error_description ? ": #{shown.call(listener.error_description)}" : ""}"
          elsif listener.timed_out?
            "no authorization callback arrived within #{WAIT_SECONDS / 60} minutes — run `rho mcp login #{row.key}` again"
          elsif message.include?("no registration_endpoint")
            "#{shown.call(message.chomp("."))} — #{CLIENT_ID_HINT}"
          else
            shown.call(message.chomp("."))
          end
        end

        # A callback that named an issuer, and not the one the consent did
        # (the gem's own comparison: a plain `==`, `iss` is no secret).
        def issuer_mismatch?(listener, provider)
          iss = listener.iss.to_s
          !iss.empty? && !provider.issuer.nil? && iss != provider.issuer.to_s
        end

        # Phase 3: the proof on the read-only view; the optional clause
        # from the store's mark.
        def prove(cli, row, storage, redact)
          connection = Connection.new(row, redact: redact, transport_factory: Rho::Mcp.transport_factory,
            storage: storage.read_only)
          begin
            connection.open!
          rescue Unavailable => error
            Commands.refuse("logged in, but #{row.key} refused the token it just issued (#{error.message}); the tokens " \
                            "are stored — run `rho mcp probe #{row.key}`")
          end
          status = storage.status
          shown = Commands.shown(redact)
          cli.out.puts "logged in to #{row.key} (issuer #{shown.call(status.issuer)}; scope #{shown.call(status.scope)}; " \
                       "#{connection.tools.length} tools listed; #{status.refresh_token ? "refresh token held" : "no refresh token"})" \
                       "#{status.optional ? OPTIONAL_CLAUSE : ""}"
          status
        ensure
          connection&.close
        end
      end

      # `rho mcp logout NAME`: the file gone whole. No revocation.
      module Logout
        module_function

        def call(cli, row, storage)
          storage.delete!
          cli.out.puts "logged out of #{row.key} (its tokens and registration forgotten; the authorization server's " \
                       "own clock expires what it issued)"
          nil
        end
      end
    end
  end
end
