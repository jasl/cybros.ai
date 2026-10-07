require "json"

module Rho
  module Acp
    class Agent
      # THE SESSION'S ENVIRONMENT:
      #
      #   session/new {cwd, additionalDirectories, mcpServers}
      #     cwd absolute (else -32602) → `Core#open_conversation(prompt:
      #     nil, directory: cwd, directories:, runner:)` — the daemon
      #     validates (422 not_a_directory / protected_root → -32602 with
      #     the sentence) → the record → the binds, each in its OWN request:
      #     `fs:` when the client advertised fs (409 runner_elsewhere logged,
      #     the session continues without the port), `mcp:` when the editor
      #     listed servers (OMITTED when it listed none — a daemon without
      #     rho-mcp answers 422 mcp_unavailable even to []; the 422 is one
      #     stderr line and the session continues; the daemon's 400
      #     malformed_body → -32602). The fs bind runs first and its 409
      #     never blocks the servers.
      #   session/load, session/resume
      #     `Core#run_row(id)` when followed, else `Core#attach(id,
      #     host_type: "conversation")` (a kernel 404 → -32002), then
      #     `bind_environment(root: cwd, directories:)`, then the fs/mcp
      #     binds. The ROOT is asserted at new/load, never per prompt;
      #     nothing moves, nothing is refused for work in flight.
      #   every session/prompt: the fs registration re-asserted (a
      #     same-tuple registration is a no-op on the daemon).
      #   close / EOF / SIGTERM: `fs: nil`, `mcp: []` best-effort (the
      #     record stays — it is the conversation's).
      #
      # `mcpServers` ride VERBATIM (stdio `{name, command, args, env:
      # [{name, value}]}`, http `{type: "http", name, url, headers}`; an
      # sse entry the daemon lists down). `additionalDirectories` beyond
      # the record's 4 KiB shape are -32602 (the spec's root set is small).
      # Not connected: -32000 naming the methods; a runner-mode
      # home: -32603 `Agent::RUNNER_MODE`; no daemon: -32603 with Core's
      # sentence.
      # EVERY REFUSAL IS READ BY ITS CODE (`Core::Refused`): `not_found` on the attach,
      # `mcp_unavailable` on the servers bind, the shared error mapping (`Errors.translate`)
      # for the rest — no sentence is matched, so a daemon rewording cannot break this surface
      # silently.
      module Environment
        ROOT_SET_BYTES = 4096
        # The two codes this door reads itself.
        MCP_UNAVAILABLE_CODE = "mcp_unavailable".freeze
        NOT_FOUND_CODE = "not_found".freeze

        module_function

        def open(agent, core, params)
          cwd = cwd!(params)
          directories = directories!(params, cwd)
          admit!(agent, core)
          answer = begin
            core.open_conversation(prompt: nil, directory: cwd, directories: directories, runner: agent.runner)
          rescue Rho::Error => error
            raise Errors.translate(error)
          end
          id = String.try_convert(answer.dig("conversation", "public_id"))
          raise Refusal.internal("the daemon opened no conversation") if id.nil?

          session = Session.new(id: id, mode: agent.mode, model: agent.model, root: cwd, directories: directories)
          bind_live(agent, core, session, params["mcpServers"])
          session
        end

        def load(agent, core, params)
          id = String.try_convert(params["sessionId"])
          raise Refusal.invalid_params("sessionId must be a string") if id.nil? || id.empty?

          cwd = cwd!(params)
          directories = directories!(params, cwd)
          admit!(agent, core)
          row = attach!(core, id)
          begin
            core.bind_environment(id, root: cwd, directories: directories)
          rescue Rho::Error => error
            raise Errors.translate(error)
          end
          session = Session.new(id: id, mode: agent.mode, model: agent.model, root: cwd, directories: directories)
          session.last_turn = row["turn"]
          session.last_variant = row["variant"]
          session.last_loop = row["run_public_id"]
          bind_live(agent, core, session, params["mcpServers"])
          session
        end

        # Per prompt: the port's registration re-asserted.
        def assert(agent, core, session)
          agent.fs_port&.register(core, session)
          nil
        end

        # Close / EOF / SIGTERM: best-effort, every step shielded.
        def release(agent, session)
          core = agent.core
          agent.fs_port&.drop(core, session)
          return unless session.servers

          begin
            core.bind_environment(session.id, mcp: [])
          rescue Rho::Error, Rho::ConnectionError
            nil
          end
          nil
        rescue StandardError => error
          agent.say("the session #{session.id} was not released cleanly (#{error.class}: #{error.message})")
        end

        # ---- the pieces ----

        def cwd!(params)
          cwd = String.try_convert(params["cwd"])
          raise Refusal.invalid_params("cwd must be an absolute path") unless cwd && cwd.start_with?("/")

          cwd
        end

        def directories!(params, cwd)
          return [] unless params.key?("additionalDirectories")

          directories = Array.try_convert(params["additionalDirectories"])&.map { |path| String.try_convert(path) }
          raise Refusal.invalid_params("additionalDirectories must be a list of absolute paths") unless
            directories && directories.all? { |path| path && path.start_with?("/") }
          raise Refusal.invalid_params("the root set exceeds #{ROOT_SET_BYTES} bytes") if
            JSON.generate([cwd, *directories]).bytesize > ROOT_SET_BYTES

          directories
        end

        # The three doors before any open: the mode, the daemon, the connection.
        def admit!(agent, core)
          raise Refusal.internal(RUNNER_MODE) if runner_mode?(core)

          daemon = core.require_daemon
          Auth.connected!(agent, core, daemon)
        rescue Rho::Error => error
          raise Errors.translate(error)
        end

        def runner_mode?(core)
          core.config.mode == "runner"
        rescue Rho::Error
          false
        end

        # Followed already, else attached. The kernel's 404 — the daemon's attach arm relays it
        # as the kernel's own `not_found` — is -32002, and ONLY that code; every other refusal
        # is the shared error mapping (a 503 `daemon_stopping`, say, is -32603 with its code,
        # never "not found").
        def attach!(core, id)
          core.follower_row(id)
        rescue Rho::Error
          begin
            core.attach(id, host_type: "conversation")["run"] || {}
          rescue Rho::Core::Refused => error
            raise Refusal.not_found(error.message) if error.code == NOT_FOUND_CODE

            raise Errors.translate(error)
          rescue Rho::Error => error
            raise Errors.translate(error)
          end
        end

        # The live members, each its own request.
        def bind_live(agent, core, session, servers)
          agent.fs_port&.register(core, session)
          bind_servers(agent, core, session, servers)
        end

        def bind_servers(agent, core, session, servers)
          return if servers.nil?

          servers = Array.try_convert(servers)&.map { |server| Hash.try_convert(server) }
          raise Refusal.invalid_params("mcpServers must be a list of server objects") unless
            servers && servers.none?(&:nil?)
          return if servers.empty?

          core.bind_environment(session.id, mcp: servers)
          session.servers = true
        rescue Rho::Core::Refused => error
          # No registrar (a daemon without rho-mcp): one stderr line and the session continues.
          # Every other code is the shared error mapping — the door's 400 `malformed_body` for a
          # list it refuses is -32602.
          raise Errors.translate(error) unless error.code == MCP_UNAVAILABLE_CODE

          agent.say("the editor's MCP servers were not bound for #{session.id} (#{error.message})")
        rescue Rho::Error => error
          raise Errors.translate(error)
        end
      end
    end
  end
end
