require "json"
require "async"
require "async/http/client"
require "async/http/endpoint"
require "async/websocket/client"
require_relative "rpc_schema"

module Rho
  module T3
    # A finite unary Effect RPC client, not a second native execution engine.
    # Every call authenticates afresh; mutations are never retried here.
    class Bridge
      LIMIT = 4 * 1024 * 1024
      TICKET_LIMIT = 65_536
      OPEN_TIMEOUT = 10
      RPC_TIMEOUT = 20
      TIMEOUT = 30
      HEARTBEAT = 5
      INCOMPATIBLE = "T3 requires orchestration protocol 2; install a compatible T3 build".freeze
      UNAVAILABLE = "T3 RPC failed; reconcile the existing work".freeze

      # Bound each frame before allocating its body, and fragmented messages
      # before the WebSocket library joins their payloads. Compression is off.
      class BoundedFramer < SimpleDelegator
        def initialize(framer)
          super
          @bytes = 0
        end

        def read_frame
          frame = __getobj__.read_frame(LIMIT)
          unless frame.control?
            @bytes += frame.payload.bytesize
            raise Error, "T3 response exceeded the 4 MiB bound" if @bytes > LIMIT

            @bytes = 0 if frame.finished?
          end
          frame
        end
      end

      class Connection < Async::WebSocket::Connection
        def initialize(framer, ...)
          super(BoundedFramer.new(framer), ...)
        end
      end

      def initialize(settings)
        @settings = settings
      end

      def projects
        http_json("GET", "/api/projects").fetch("projects")
      rescue KeyError, TypeError, NoMethodError
        raise Error, "T3 returned an incomplete project directory", cause: nil
      end

      def create_project(path:, title:)
        http_json("POST", "/api/projects/mutate", {
          "type" => "project.create", "commandId" => SecureRandom.uuid_v7,
          "projectId" => SecureRandom.uuid_v7, "title" => title, "workspaceRoot" => path,
        })
      end

      def call(method, params, cancelled: true)
        RpcSchema.validate!(method, params)
        context = Rho::Runner::ExecutionContext.current if cancelled
        context&.raise_if_cancelled!
        value, error = Sync do |parent|
          operation = parent.async do |task|
            [task.with_timeout(TIMEOUT) { exchange(task, method, params) }, nil]
          rescue Error => error
            [nil, error]
          rescue StandardError
            # Neither Async diagnostics nor callers receive a credential URL,
            # remote failure cause or provider output from a failed exchange.
            [nil, Uncertain.new(UNAVAILABLE)]
          end
          watcher = parent.async do
            until operation.finished?
              sleep(0.1)
              operation.stop if context.cancelled?
            end
          end if context
          operation.wait
        ensure
          watcher&.stop
        end
        context&.raise_if_cancelled!
        raise error, cause: nil if error

        value
      end

      private

      def http_json(method, path, body = nil)
        @settings.require_connection
        value, error = Sync do |task|
          [task.with_timeout(TIMEOUT) do
            endpoint = Async::HTTP::Endpoint.parse("#{@settings.url}#{path}")
            client = Async::HTTP::Client.new(endpoint, retries: 0, limit: 1)
            headers = { "authorization" => "Bearer #{@settings.token}", "content-type" => "application/json" }
            response = if method == "GET"
              client.get(endpoint.path, headers)
            else
              client.post(endpoint.path, headers, JSON.generate(body))
            end
            unless (200..299).cover?(response.status)
              raise Error, "T3 project request failed (HTTP #{response.status})"
            end
            bytes = +""
            response.body.each do |chunk|
              bytes << chunk
              raise Error, "T3 project response exceeded the 4 MiB bound" if bytes.bytesize > LIMIT
            end
            JSON.parse(bytes).to_h
          ensure
            response&.close
            client&.close
          end, nil]
        rescue Error => error
          [nil, error]
        rescue StandardError
          [nil, Uncertain.new("T3 project response was unavailable; read the project list before another create")]
        end
        raise error, cause: nil if error

        value
      end

      def exchange(task, method, params)
        ticket = task.with_timeout(OPEN_TIMEOUT) { ticket! }
        endpoint = Async::HTTP::Endpoint.parse("#{@settings.url}/ws?#{URI.encode_www_form(wsTicket: ticket, orchestrationProtocol: 2)}")
        Async::WebSocket::Client.open(endpoint, retries: 0, limit: 1) do |client|
          connection = task.with_timeout(OPEN_TIMEOUT) { client.connect(endpoint.authority, endpoint.path, handler: Connection, extensions: nil) }
          heartbeat = task.async do
            loop do
              sleep(HEARTBEAT)
              send_frame(connection, { "_tag" => "Ping" })
            end
          rescue StandardError
            connection.close
          end
          task.with_timeout(RPC_TIMEOUT) do
            config = request(connection, "0", "server.getConfig", {})
            raise Error, INCOMPATIBLE unless config.to_h.dig("environment", "orchestrationProtocolVersion") == 2

            method == "server.getConfig" ? config : request(connection, "1", method, params)
          end
        ensure
          heartbeat&.stop
          connection&.close
        end
      rescue Async::WebSocket::ConnectionError => error
        incompatible = error.response.status == 426
        error.response.close
        raise(incompatible ? Error.new(INCOMPATIBLE) : Uncertain.new(UNAVAILABLE), cause: nil)
      end

      def ticket!
        endpoint = Async::HTTP::Endpoint.parse("#{@settings.url}/api/auth/websocket-ticket")
        client = Async::HTTP::Client.new(endpoint, retries: 0, limit: 1)
        response = client.post(endpoint.path, { "authorization" => "Bearer #{@settings.token}" })
        raise Error, "T3 ticket authentication failed" unless response.status == 200

        bytes = +""
        response.body.each do |chunk|
          bytes << chunk
          raise Error, "T3 ticket exceeded the 64 KiB bound" if bytes.bytesize > TICKET_LIMIT
        end
        ticket = JSON.parse(bytes).to_h.fetch("ticket").to_str
        raise Error, "T3 returned an empty WebSocket ticket" if ticket.empty?

        ticket
      ensure
        response&.close
        client&.close
      end

      def request(connection, id, method, params)
        send_frame(connection, { "_tag" => "Request", "id" => id, "tag" => method, "payload" => params, "headers" => [] })
        loop do
          message = connection.read or raise Uncertain, UNAVAILABLE
          [JSON.parse(message.to_str)].flatten(1).each do |value|
            frame = value.to_h
            case frame.fetch("_tag")
            when "Pong" then next
            when "Ping" then send_frame(connection, { "_tag" => "Pong" })
            when "Exit"
              raise Uncertain, UNAVAILABLE unless frame.fetch("requestId") == id

              result = frame.fetch("exit").to_h
              raise Uncertain, UNAVAILABLE unless result.fetch("_tag") == "Success"

              return result.fetch("value", nil)
            else raise Uncertain, UNAVAILABLE
            end
          end
        end
      end

      def send_frame(connection, frame)
        bytes = JSON.generate(frame)
        raise Error, "T3 request exceeded the 4 MiB bound" if bytes.bytesize > LIMIT

        connection.write(bytes)
        connection.flush
      end
    end
  end
end
