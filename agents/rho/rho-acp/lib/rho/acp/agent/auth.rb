require "securerandom"

module Rho
  module Acp
    class Agent
      # AUTH ↔ NEXUS CONNECT. `authMethods` is ALWAYS non-empty (the registry's
      # `--auth-check`): `nexus` (agent type) opens the device page —
      # `start_ceremony(daemon)` → the code document (read off the status
      # when a joined start answers without one) → `elicitation/create
      # {mode: "url", url: verification_uri_complete, message}` when the
      # client advertised `elicitation.url`, else -32000 whose message
      # carries the URL and the code; the status polled until connected
      # (the `Cli::Connect` wait); `elicitation/complete` closes the card;
      # `{}`. Already connected → `{}` at once. Unknown id → -32602. When
      # the client advertised `clientCapabilities.auth.terminal` the
      # `connect` method (terminal type, `args: ["connect"]`) is offered
      # too: the client runs the configured program with the word appended
      # — `rho-acp connect`, the ceremony on plain stdio — then reconnects
      # and re-initializes. No `logout`.
      #
      # NOT CONNECTED (`stored_connection` nil, or the daemon's status not
      # `active`): `session/new` and the loads answer -32000 naming the
      # methods (`Auth.connected!`).
      module Auth
        NEXUS = { "id" => "nexus", "name" => "Connect this machine to Nexus", "description" => "opens the device page" }.freeze
        TERMINAL = {
          "id" => "connect", "type" => Acp::Methods::AuthMethodType::TERMINAL, "name" => "Connect from the terminal",
          "args" => ["connect"],
        }.freeze
        POLL_SECONDS = 1
        # The daemon answers 503 `connection_bootstrapping` between binding
        # and finishing its staging inspection (`Cli::Connect::BOOTSTRAP_WAIT`).
        BOOTSTRAP_WAIT = 30
        ACTIVE = "active".freeze

        module_function

        def initialize_document(agent)
          {
            "protocolVersion" => Acp::Methods::PROTOCOL_VERSION,
            "agentInfo" => { "name" => "rho", "title" => "rho", "version" => Rho::VERSION },
            "agentCapabilities" => {
              "loadSession" => true,
              "promptCapabilities" => { "image" => true, "audio" => false, "embeddedContext" => true },
              "mcpCapabilities" => { "http" => true, "sse" => false },
              "sessionCapabilities" => { "resume" => {}, "close" => {}, "additionalDirectories" => {} },
            },
            "authMethods" => methods(agent),
          }
        end

        def methods(agent)
          agent.client.auth_terminal? ? [NEXUS, TERMINAL] : [NEXUS]
        end

        def method_ids(agent) = methods(agent).map { |method| method.fetch("id") }

        # `authenticate {methodId}`.
        def authenticate(agent, core, params)
          raise Refusal.invalid_params("unknown auth method #{params["methodId"].inspect}; one of #{method_ids(agent).join(", ")}") unless
            params["methodId"] == NEXUS.fetch("id")

          daemon = core.require_daemon
          return {} if connected?(core, daemon)

          started = start(core, daemon)
          raise Refusal.internal(core.failure_message(started)) if started["error"] || started["phase"] == "error"
          return {} if started["phase"] == ACTIVE

          # A start that JOINED another client's ceremony answers the bare
          # `starting` or `activating` phase once the daemon's short wait
          # runs out, with no code and no URL: the status is polled as
          # `Cli::Connect` does until a document carries the code, and a
          # connection that completes first needs no card at all.
          coded = code?(started) ? started : wait_for(core, daemon) { |connection| connection if code?(connection) }
          return {} if coded.nil?

          card(agent, core, daemon, coded)
        end

        # The ceremony's start, retried through the daemon's own
        # bootstrapping window alone.
        def start(core, daemon)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOTSTRAP_WAIT
          loop do
            started = core.start_ceremony(daemon)
            error = started["error"]
            return started unless error.is_a?(Hash) && error["code"] == "connection_bootstrapping" &&
              Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

            sleep POLL_SECONDS
          end
        end

        # The code as a card when the client shows one, else the -32000
        # whose message carries the URL and the code.
        def card(agent, core, daemon, started)
          url = started["verification_uri_complete"]
          code = started["user_code"]
          message = "Open #{started["verification_uri"]} and enter: #{code}"
          unless agent.client.elicitation_url?
            raise Refusal.auth_required("#{message} — then call authenticate again",
              data: { "url" => url, "code" => code }.compact)
          end

          elicitation = SecureRandom.hex(8)
          pending = agent.connection.request(Acp::Methods::ELICITATION_CREATE,
            "elicitationId" => elicitation, "mode" => "url", "url" => url, "message" => message)
          begin
            wait_connected(core, daemon, pending)
          ensure
            complete(agent, elicitation)
          end
          {}
        end

        # The wait for the connection the card opened; a card the client
        # declined ends it.
        def wait_connected(core, daemon, pending)
          wait_for(core, daemon) do
            declined!(pending) if pending.done?
            nil
          end
        end

        # The `Cli::Connect` wait: the status polled until the block answers
        # something from its ceremony document, or the connection is active
        # (nil); the ceremony's own error and a ceremony gone from the status
        # are refused.
        def wait_for(core, daemon)
          loop do
            status = core.status_document(daemon)
            connection = Hash.try_convert(status["connection"]) || {}
            raise Refusal.internal(core.failure_message(connection)) if connection["phase"] == "error"
            return nil if status["state"] == ACTIVE && (connection["phase"].nil? || connection["phase"] == ACTIVE)
            raise Refusal.internal("the connection is no longer in flight") if status["state"] == "disconnected" && status["connection"].nil?

            answer = yield(connection)
            return answer if answer

            sleep POLL_SECONDS
          end
        end

        # Whether a ceremony document carries the code a person enters, the
        # test `Cli::Connect` announces by.
        def code?(document) = document["user_code"].is_a?(String) && !document["user_code"].empty?

        def declined!(pending)
          result = Hash.try_convert(pending.wait) || {}
          return if result["action"] == Acp::Methods::ElicitationAction::ACCEPT

          raise Refusal.auth_required("the device page was #{result["action"] || "closed"} before the connection completed")
        rescue RemoteError, Closed
          raise Refusal.auth_required("the device card went away before the connection completed")
        end

        def complete(agent, elicitation)
          agent.connection.notify(Acp::Methods::ELICITATION_COMPLETE, "elicitationId" => elicitation)
        rescue Closed
          nil
        end

        # Whether this home is connected: a stored pointer, and a daemon
        # whose status is active.
        def connected?(core, daemon)
          return false if core.stored_connection.nil?

          core.status_document(daemon)["state"] == ACTIVE
        end

        def connected!(agent, core, daemon)
          return if connected?(core, daemon)

          raise Refusal.auth_required("this machine is not connected to Nexus: authenticate with one of #{method_ids(agent).join(", ")}",
            data: { "authMethods" => method_ids(agent) })
        end
      end
    end
  end
end
