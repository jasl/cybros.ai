require "async/http/server"
require "async/websocket/adapters/http"
require "protocol/http/response"

module T3Test
  # Real HTTP and WebSocket framing, with only the adopted RPC surface scripted.
  class Server
    attr_reader :http_requests, :rpc_requests, :frames

    def initialize(ticket_status: 200, ticket_body: nil, version: 2, upgrade_status: nil, stall_ticket: false, projects: nil, &behavior)
      @ticket_status = ticket_status
      @ticket_body = ticket_body || JSON.generate({ "ticket" => "fixture-ticket" })
      @version, @upgrade_status, @stall_ticket, @behavior = version, upgrade_status, stall_ticket, behavior
      @projects = projects
      @http_requests, @rpc_requests, @frames, @connections, @handlers = [], [], [], [], []
    end

    def start(task)
      @bound = Async::HTTP::Endpoint.parse("http://127.0.0.1:0").bound
      server = Async::HTTP::Server.new(method(:serve), @bound, protocol: Async::HTTP::Protocol::HTTP1, scheme: "http")
      @task = task.async { server.run }
      self
    end

    def url = "http://127.0.0.1:#{@bound.sockets.first.local_address.ip_port}"

    def stop
      @task&.stop
      @handlers.each(&:stop)
      @connections.each(&:close)
      @bound&.close
    end

    def send_frame(connection, frame)
      connection.write(JSON.generate(frame))
      connection.flush
    end

    def success(connection, frame, value)
      send_frame(connection, { "_tag" => "Exit", "requestId" => frame.fetch("id"), "exit" => { "_tag" => "Success", "value" => value } })
    end

    private

    def serve(request)
      @handlers << Async::Task.current
      @http_requests << { method: request.method, path: request.path, authorization: request.headers["authorization"], compression: request.headers["sec-websocket-extensions"] }
      if @projects && request.path.start_with?("/api/projects")
        value = if request.method == "GET"
          { "projects" => @projects }
        else
          body = JSON.parse(request.body.read)
          @http_requests.last[:body] = body
          { "id" => body.fetch("projectId"), "title" => body.fetch("title"), "workspaceRoot" => body.fetch("workspaceRoot") }
        end
        return Protocol::HTTP::Response[200, { "content-type" => "application/json" }, [JSON.generate(value)]]
      end
      if request.path == "/api/auth/websocket-ticket"
        sleep(60) if @stall_ticket
        return Protocol::HTTP::Response[@ticket_status, { "location" => "#{url}/forbidden" }, [@ticket_body]]
      end
      return Protocol::HTTP::Response[@upgrade_status, {}, ["fixture-ticket fixture-bearer"]] if @upgrade_status

      Async::WebSocket::Adapters::HTTP.open(request, extensions: nil) do |connection|
        @connections << connection
        while message = connection.read
          [JSON.parse(message.to_str)].flatten(1).each do |frame|
            @frames << frame
            if frame.fetch("_tag") == "Ping"
              send_frame(connection, { "_tag" => "Pong" })
              next
            end
            next unless frame.fetch("_tag") == "Request"

            @rpc_requests << frame
            if frame.fetch("tag") == "server.getConfig"
              success(connection, frame, { "environment" => { "orchestrationProtocolVersion" => @version }, "providers" => T3Test.provider_catalog })
            elsif @behavior
              @behavior.call(self, connection, frame)
            else
              success(connection, frame, { "received" => frame.fetch("payload") })
            end
          end
        end
      rescue IOError, SystemCallError, Protocol::WebSocket::Error
        nil
      end
    end
  end
end
