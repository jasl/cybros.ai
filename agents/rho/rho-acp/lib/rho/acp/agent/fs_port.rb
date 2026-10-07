require "json"
require "openssl"
require "securerandom"

module Rho
  module Acp
    class Agent
      # THE FILE-SYSTEM PORT'S SURFACE HALF: the loopback endpoint the daemon's
      # `Rho::Extensions::Environment::FsPort` posts to, each request
      # relayed 1:1 to the editor over the connection. A
      # `Rho::ControlServer` on its own thread — `127.0.0.1`, an ephemeral
      # port, a two-row route table of its own (no `Daemon::Routes`), the
      # bearer a per-process `SecureRandom.hex(32)` checked with
      # `OpenSSL.secure_compare` in the handlers.
      #
      # THE WIRE, as the daemon's client (E2) fixed it:
      #   POST /fs/read  {path, line?, limit?}  → 200 {text}
      #   POST /fs/write {path, text}           → 200 {ok: true}
      #   a refusal                             → 4xx {error: {code, message}}
      #     `not_found`   the client's -32002 (resource_not_found)
      #     `beyond_eof`  Zed's -32602 past the last line; harbor's "" for line > 1
      #     `cancelled`   -32800
      #     `editor_refused` any other client error (the daemon reads any
      #                   other 4xx code as Refused under that code)
      #   a 401/403 is a broken bearer; a 5xx or a timeout is Unavailable.
      # Each read is `fs/read_text_file {sessionId, path, line?, limit?}` →
      # `{content}`, each write `fs/write_text_file {sessionId, path,
      # content}` → `{}` — through the landed `Connection` (`Pending#wait
      # (timeout:)`), `$/cancel_request` on the surface's own timeout
      # (shorter than the daemon's 30 s read / 60 s write clocks, so the
      # cancel goes out before the daemon gives up). THE SESSION a read
      # belongs to: the daemon's request names a path and no session, so
      # the row is the newest session whose root set holds the path
      # (`Sessions#for_path`); one editor window is one process.
      #
      # REGISTRATION: `Core#bind_environment(id, fs: {url, token, read:,
      # write:, client: clientInfo.name})` at `session/new`/`load` after
      # `initialize` told the surface `clientCapabilities.fs` — never a
      # flag the client did not advertise — re-asserted every prompt (a
      # same-tuple registration is a no-op on the daemon), `fs: nil` on
      # close, EOF and SIGTERM (best-effort). The door's 409
      # `runner_elsewhere` (a remote-runner row) is logged and the session
      # continues without the port.
      class FsPort
        BIND = "127.0.0.1".freeze
        READ_ROUTE = "/fs/read".freeze
        WRITE_ROUTE = "/fs/write".freeze
        READ_WAIT = 25
        WRITE_WAIT = 55
        BEARER = /\ABearer (.+)\z/

        attr_reader :url
        # The surface's own clocks, shorter than the daemon's; a test
        # shortens them further.
        attr_accessor :read_wait, :write_wait

        def initialize(agent)
          @agent = agent
          @bearer = SecureRandom.hex(32)
          @server = nil
          @url = nil
          @read_wait = READ_WAIT
          @write_wait = WRITE_WAIT
        end

        def start
          @server = Rho::ControlServer.new(bind: BIND, port: 0, routes: {
            ["POST", READ_ROUTE] => ->(request) { serve(request) { |body, session| read(body, session) } },
            ["POST", WRITE_ROUTE] => ->(request) { serve(request) { |body, session| write(body, session) } },
          }).run
          @url = "http://#{BIND}:#{@server.port}"
          self
        end

        def stop
          @server&.stop
          @server = nil
          nil
        end

        # ---- registration (through the core) ----

        # The tuple the daemon keeps under the record's anchor.
        def registration
          {
            "url" => @url, "token" => @bearer, "read" => @agent.client.fs_read?, "write" => @agent.client.fs_write?,
            "client" => @agent.client.name,
          }
        end

        # At new/load and re-asserted per prompt; a refusal (409
        # `runner_elsewhere`, a daemon without the door) is one stderr
        # line and the session goes on without the port.
        def register(core, session)
          core.bind_environment(session.id, fs: registration)
          true
        rescue Rho::Error => error
          @agent.say("the file-system port was not registered for #{session.id} (#{error.message})")
          false
        end

        def drop(core, session)
          core.bind_environment(session.id, fs: nil)
          nil
        rescue Rho::Error, Rho::ConnectionError
          nil
        end

        private

          # The bearer, the body, the session; the block's answer or the
          # refusal's status and envelope.
          def serve(request)
            presented = Array(request.headers["authorization"]).first.to_s[BEARER, 1].to_s
            return [401, error("unauthorized", "the bearer is not this surface's")] unless
              presented.bytesize == @bearer.bytesize && OpenSSL.secure_compare(presented, @bearer)

            body = Rho::ControlServer.json_body(request)
            path = body["path"]
            return [400, error("malformed_body", "path is required")] unless path.is_a?(String) && !path.empty?

            session = @agent.sessions.for_path(path)
            return [503, error("no_session", "no session is open on this surface")] if session.nil?

            yield(body, session)
          rescue Rho::ControlServer::MalformedBody => e
            [400, error("malformed_body", e.message)]
          end

          def read(body, session)
            unless @agent.client.fs_read?
              return [422, error("editor_refused", "#{@agent.client.name} did not advertise fs.readTextFile")]
            end

            params = { "sessionId" => session.id, "path" => body["path"] }
            params["line"] = body["line"] if body["line"].is_a?(Integer)
            params["limit"] = body["limit"] if body["limit"].is_a?(Integer)
            call_tool(Acp::Methods::FS_READ_TEXT_FILE, params, @read_wait) do |result|
              content = Hash.try_convert(result)&.dig("content")
              next [502, error("malformed", "the editor answered no content")] unless content.is_a?(String)
              next [422, error("beyond_eof", "line #{body["line"]} is beyond the end of #{body["path"]}")] if
                content.empty? && body["line"].is_a?(Integer) && body["line"] > 1

              [200, { text: content }]
            end
          end

          def write(body, session)
            unless @agent.client.fs_write?
              return [422, error("editor_refused", "#{@agent.client.name} did not advertise fs.writeTextFile")]
            end
            return [400, error("malformed_body", "text must be a string")] unless body["text"].is_a?(String)

            params = { "sessionId" => session.id, "path" => body["path"], "content" => body["text"] }
            call_tool(Acp::Methods::FS_WRITE_TEXT_FILE, params, @write_wait) { |_result| [200, { ok: true }] }
          end

          # One request, one wait, the codes of the table.
          def call_tool(method, params, wait)
            pending = @agent.connection.request(method, params)
            yield(pending.wait(timeout: wait))
          rescue Unanswered
            pending&.cancel
            [504, error("timeout", "the editor did not answer #{method} within #{wait}s")]
          rescue RemoteError => e
            refused(e)
          rescue Closed
            [503, error("closed", "the editor went away")]
          end

          def refused(e)
            case e.code
            when Acp::Methods::ErrorCode::RESOURCE_NOT_FOUND then [404, error("not_found", e.message)]
            when Acp::Methods::ErrorCode::INVALID_PARAMS then [422, error("beyond_eof", e.message)]
            when Acp::Methods::ErrorCode::REQUEST_CANCELLED then [409, error("cancelled", e.message)]
            else [422, error("editor_refused", e.message)]
            end
          end

          def error(code, message) = { error: { code: code, message: message } }
      end
    end
  end
end
