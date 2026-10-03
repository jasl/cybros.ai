module Rho
  module Extensions
    # The door to the page: a console code
    # moves a bearer already held into a browser that cannot read the 0600
    # announcement; boot prints none, since a supervisor merges stdout into a file it does not own.
    module ConsoleLink
      NAME = "rho.console_link".freeze
      # The boundary this closes: a process that can open 127.0.0.1:PORT but
      # cannot read the announcement — another local uid, or a container with
      # host networking that rho itself started. A same-uid process is not in scope.
      CONSOLE_HEADER = "x-rho-console".freeze
      CONSOLE_FRAGMENT = "code".freeze

      # One code table per load, so two daemons in one process never redeem
      # each other's.
      def self.register(api)
        codes = ConsoleCodes.new
        # Minting is guarded; redeeming cannot be, which is exactly why
        # minting is.
        api.register_route("POST", "/console/code") { |_request, ctx| Routes.mint(codes, ctx) }
        api.register_route("POST", "/console/session", auth: :none) { |request, ctx| Routes.session(codes, request, ctx) }
        api.register_command("console",
          description: "Open this daemon's page — mints a single-use link the browser can redeem",
          long_description: <<~TEXT,
            The page cannot read the announcement — it is 0600 and a browser is not a
            file reader — so this mints a single-use code that redeems for the same
            bearer, valid for 90 seconds.

            NOTHING IS PRINTED AT BOOT, deliberately: a code on `rho server`'s stdout
            would land in a process supervisor's merged log, whose permissions this
            daemon does not own. This command reads the 0600 announcement, which is
            what proves it may ask at all.
          TEXT
          options: { open: { type: :boolean, default: false, desc: "Launch a browser at the link" } },
          &Commands.method(:console))
      end

      module Routes
        class << self
          # Minting requires the bearer, so this can never be a way to obtain
          # a credential, only to move one already held into a page.
          def mint(codes, ctx)
            unless ctx.page?
              return Rho::Daemon::Refusal.new(status: 409, code: "page_not_served",
                message: "This daemon serves no console page")
            end

            code = codes.mint
            ctx.log.info("console.code_minted", fingerprint: ConsoleCodes.fingerprint(code),
              expires_in_seconds: ConsoleCodes::TTL_SECONDS)
            [200, { url: "#{ctx.endpoint}##{CONSOLE_FRAGMENT}=#{code}", code: code,
                    home: ctx.home.root, expires_in_seconds: ConsoleCodes::TTL_SECONDS }]
          end

          # The one unauthenticated route that answers with a bearer: the
          # code exists because a bearer holder asked, dies in 90 seconds and
          # works once. The custom header is not CORS-safelisted, so a visited page's preflight never arrives.
          def session(codes, request, ctx)
            unless Array(request.headers[CONSOLE_HEADER]).first.to_s == "1"
              return Rho::Daemon::Refusal.new(status: 403, code: "console_header_required",
                message: "POST /console/session requires #{CONSOLE_HEADER}: 1")
            end

            # Body first, then one decision: a compare that straddles the
            # body's socket await is not one critical section.
            body = ControlServer.json_body(request)
            return Rho::Daemon::Refusal.stopping if ctx.stopping?

            code = body["code"].to_s
            if code.empty?
              return Rho::Daemon::Refusal.new(status: 400, code: "missing_code",
                message: %(Send {"code": "..."} from `rho console`))
            end

            redeem(codes, code, ctx)
          end

          private

            def redeem(codes, code, ctx)
              case codes.redeem(code)
              when :ok
                ctx.log.info("console.code_redeemed", fingerprint: ConsoleCodes.fingerprint(code))
                [200, { bearer: ctx.bearer }]
              when :spent
                # The only theft signal this design has, so it gets its own
                # status, words and log line.
                ctx.log.warn("console.code_replayed", fingerprint: ConsoleCodes.fingerprint(code))
                Rho::Daemon::Refusal.new(status: 409, code: "code_spent",
                  message: "This console link was already used. If that was not you, stop this " \
                           "daemon — the bearer it minted grants this host's shell.")
              else
                ctx.log.warn("console.code_unknown")
                Rho::Daemon::Refusal.new(status: 401, code: "code_unknown",
                  message: "No live console code matches. Run `rho console` for a fresh link.")
              end
            end
        end
      end

      module Commands
        class << self
          # Restart, second tab, reload and a stale bookmark all have the same
          # answer: run it again. Reading the 0600 announcement is what proves
          # this caller may have a bearer at all.
          def console(cli, _args, options)
            daemon = cli.core.require_daemon
            response = cli.core.post(daemon, "/console/code", budget: Rho::Core::Budget::KERNEL_ROUND_TRIP)
            document = cli.core.parse(response)
            unless response.code.to_i == 200
              raise Rho::Error, document.dig("error", "message") || "the daemon refused a console code"
            end

            cli.out.puts "console: #{document.fetch("url")}"
            cli.out.puts "home:    #{document.fetch("home")}"
            cli.out.puts "code:    #{document.fetch("code")}   " \
                         "(paste this if your browser reaches this daemon at another address)"
            cli.out.puts "expires: #{document.fetch("expires_in_seconds")}s, single use — " \
                         "run `rho console` again for another"
            # The ONE launcher (`Rho::Cli::Browser`, `$BROWSER` honoured), never
            # fatal: the URL is already on screen.
            Rho::Cli::Browser.launch(document.fetch("url"), out: cli.out) if options[:open]
            document
          end
        end
      end
    end
  end
end
