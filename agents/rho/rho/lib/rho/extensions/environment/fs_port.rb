require "json"
require "net/http"
require "uri"

module Rho
  module Extensions
    module Environment
      # THE DAEMON'S SIDE OF THE FILE-SYSTEM PORT: the runner gem's duck (`Rho::Runner::
      # FsPort` — `serves?`, `read_text`, `write_text`, `drop`, `client`)
      # spoken over stdlib `Net::HTTP` to the loopback URL the surface
      # registered through the door's `fs:` member, the bearer on every
      # request. Two routes, two shapes: `POST /fs/read {path, line?,
      # limit?}` → 200 `{text}`; `POST /fs/write {path, text}` → 200 `{ok}`;
      # a refusal is a 4xx `{error: {code, message}}`. ONE ERROR TABLE, the
      # duck's: `not_found`, `beyond_eof` and `cancelled` are their own
      # errors, any other 4xx code is `Refused` with that code (the editor
      # said no), and everything that is not an answer — a refused
      # connection, a timeout, a 5xx, a 401 (the bearer is the surface's;
      # a mismatch is a broken port, never the editor's word), a body that
      # is not the shape — is `Unavailable`. The runner's `FsPort.ask`
      # drops the port on `Unavailable` (`drop`, once: the table's
      # callback); the client itself drops nothing, so a direct caller
      # reads the same error the tools do.
      #
      # THE CLOCKS: 2 s to open, 30 s for a read, 60 s for a write (Zed
      # runs `format_on_save` before `project.save_buffer`). THE WORKER'S
      # CANCEL SIGNAL FINISHES THE SESSION (`ExecutionContext.with_cancel_
      # signal`): the socket closes on the signal, the wait ends at once,
      # and the tool sees `Cancelled`. The token never rides an inspection
      # or a log line: `inspect` names the client and the flags alone.
      class FsPort
        include Rho::Runner::FsPort

        OPEN_TIMEOUT_SECONDS = 2
        READ_TIMEOUT_SECONDS = 30
        WRITE_TIMEOUT_SECONDS = 60
        READ_ROUTE = "/fs/read".freeze
        WRITE_ROUTE = "/fs/write".freeze
        # The codes with an error of their own; every other 4xx code is
        # `Refused` under that code.
        CODES = {
          "not_found" => Rho::Runner::FsPort::NotFound,
          "beyond_eof" => Rho::Runner::FsPort::BeyondEof,
          "cancelled" => Rho::Runner::FsPort::Cancelled,
        }.freeze
        # A bearer refusal is the surface's, not the editor's.
        BROKEN_STATUSES = [401, 403].freeze

        attr_reader :client, :url

        def initialize(url:, token:, read:, write:, client:, on_drop: nil, open_timeout: OPEN_TIMEOUT_SECONDS,
                       read_timeout: READ_TIMEOUT_SECONDS, write_timeout: WRITE_TIMEOUT_SECONDS)
          @url = url
          @token = token
          @read = read ? true : false
          @write = write ? true : false
          @client = client
          @on_drop = on_drop
          @open_timeout = open_timeout
          @read_timeout = read_timeout
          @write_timeout = write_timeout
          @dropped = false
          @mutex = Mutex.new
        end

        def serves?(need)
          case need
          when :read then @read
          when :write then @write
          else false
          end
        end

        # What the door and the live table show: never the token or the URL.
        def describe = { client: @client, read: @read, write: @write }

        # THE RE-ASSERTION'S NO-OP (the live members are
        # re-asserted every prompt, a tuple no-op when unchanged): whether
        # this port IS that registration — the token compared, never
        # answered.
        def same?(url:, token:, read:, write:, client:)
          @url == url && @token == token && @read == (read ? true : false) && @write == (write ? true : false) &&
            @client == client
        end

        def inspect = "#<#{self.class.name} client=#{@client.inspect} read=#{@read} write=#{@write}>"

        # A window of the buffer (`line` 1-based, `limit` lines), or the
        # whole buffer when both are nil (edit's pre-read).
        def read_text(path, line:, limit:)
          answer = post(READ_ROUTE, { "path" => path, "line" => line, "limit" => limit }.compact, timeout: @read_timeout)
          text = answer["text"]
          raise Rho::Runner::FsPort::Unavailable, "malformed: the read's answer carries no text" unless text.is_a?(String)

          text
        end

        def write_text(path, text)
          answer = post(WRITE_ROUTE, { "path" => path, "text" => text }, timeout: @write_timeout)
          raise Rho::Runner::FsPort::Unavailable, "malformed: the write's answer is not ok" unless answer["ok"] == true

          nil
        end

        # THE PORT IS UNUSABLE: leaves the table through the callback the
        # table registered, once; a second drop is nothing.
        def drop(detail)
          first = @mutex.synchronize do
            next false if @dropped

            @dropped = true
          end
          @on_drop&.call(detail) if first
          nil
        end

        def dropped? = @mutex.synchronize { @dropped }

        private

          def post(route, body, timeout:)
            context = Rho::Runner::ExecutionContext.current
            cancelled!(context) if context&.cancelled?
            http = session(timeout)
            response = Rho::Runner::ExecutionContext.with_cancel_signal(-> { finish(http) }) do
              http.start { http.request(request_for(route, body)) }
            end
            answer(response)
          rescue Net::OpenTimeout, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
                 Errno::ENETUNREACH, Errno::EADDRNOTAVAIL => error
            unavailable("refused", error)
          rescue Net::ReadTimeout, Net::WriteTimeout => error
            unavailable("timeout", error)
          rescue IOError, EOFError, Errno::EPIPE, Net::HTTPBadResponse, Net::ProtocolError => error
            # The session closed under the request: the worker's own
            # signal (the cancel path), else a surface that hung up.
            cancelled!(context) if context&.cancelled?
            unavailable("malformed", error)
          end

          # The duck's word for it; the runner's `ask` turns it into the
          # worker's own cancel path with the signal's reason.
          def cancelled!(context)
            raise Rho::Runner::FsPort::Cancelled, "the request was cancelled (#{context.reason || "cancelled"})"
          end

          def session(timeout)
            uri = URI.parse(@url)
            http = Net::HTTP.new(uri.hostname, uri.port)
            http.open_timeout = @open_timeout
            http.read_timeout = timeout
            http.write_timeout = timeout
            http
          end

          def request_for(route, body)
            request = Net::HTTP::Post.new(route)
            request["Authorization"] = "Bearer #{@token}"
            request["Content-Type"] = "application/json"
            request.body = JSON.generate(body)
            request
          end

          # From the cancel signal's thread: terminates the session's socket
          # and nothing else; a session not yet open is nothing to finish.
          def finish(http)
            http.finish if http.started?
          rescue IOError, SystemCallError
            nil
          end

          # The status decides before the body is read: a broken port
          # (the bearer refused, a 5xx) is named by its status whatever
          # the surface wrote; only an answer (200) or a refusal (4xx) has
          # a shape to parse.
          def answer(response)
            status = response.code.to_i
            raise Rho::Runner::FsPort::Unavailable, "status_#{status}: the surface refused the bearer" if
              BROKEN_STATUSES.include?(status)
            raise Rho::Runner::FsPort::Unavailable, "status_#{status}: #{response.body.to_s.byteslice(0, 200)}" unless
              status == 200 || (400..499).cover?(status)

            document = parse(response.body)
            return document if status == 200

            refuse(document, status)
          end

          def parse(body)
            document = JSON.parse(body.to_s)
            raise Rho::Runner::FsPort::Unavailable, "malformed: the answer is not a JSON object" unless document.is_a?(Hash)

            document
          rescue JSON::ParserError
            raise Rho::Runner::FsPort::Unavailable, "malformed: the answer is not JSON"
          end

          # A 4xx with a code: the client's own errors, or `Refused` under
          # the code as given; a 4xx with no code is not the shape.
          def refuse(document, status)
            error = Hash.try_convert(document["error"]) || {}
            code = error["code"]
            raise Rho::Runner::FsPort::Unavailable, "status_#{status}: a refusal with no code" unless code.is_a?(String)

            message = error["message"].to_s
            klass = CODES[code]
            raise klass, message if klass

            raise Rho::Runner::FsPort::Refused.new(message, code: code)
          end

          def unavailable(label, error)
            raise Rho::Runner::FsPort::Unavailable, "#{label}: #{error.class.name}: #{error.message}"
          end
      end
    end
  end
end
