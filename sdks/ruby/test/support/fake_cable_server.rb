require "json"
require "async"
require "async/http/endpoint"
require "async/http/server"
require "async/websocket"
require "async/websocket/adapters/http"
require "protocol/http/response"

module CybrosAgentTest
  # AN IN-PROCESS ACTIONCABLE, and the reason the client's races are testable
  # at all. A real WebSocket server on an ephemeral loopback port, so a test
  # can script exactly what a server does — stall a handshake, disconnect
  # instead of welcoming, confirm a subscription and then vanish — none of
  # which a live Rails app can be asked for on demand.
  #
  # The handshake (Authorization, offered subprotocols, Origin, path) is
  # recorded so a test can assert what the client actually presented.
  #
  # The behavior block owns the connection's lifetime: when it returns, the
  # adapter closes the socket. A script that must keep the connection open
  # while the client drives the scenario ends with `session.drain`.
  class FakeCableServer
    PROTOCOL = "actioncable-v1-json"

    attr_reader :handshakes

    def initialize(&behavior)
    @behavior = behavior
    @handshakes = []
    @sessions = []
    @bound = nil
    @server_task = nil
    end

    def start(task)
    endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:0")
    @bound = endpoint.bound
    server = Async::HTTP::Server.new(
      build_app, @bound, protocol: Async::HTTP::Protocol::HTTP1, scheme: "http"
    )
    @server_task = task.async { server.run }
    self
    end

    def base_url
    "http://127.0.0.1:#{port}"
    end

    def port
    @bound.sockets.first.local_address.ip_port
    end

    # Stops accepting AND force-closes live websockets: the per-connection
    # fibers are scheduled by io-endpoint outside the server task, so
    # stopping the task alone would leave a blocked-in-read behavior fiber
    # keeping the reactor alive forever.
    def stop
    @server_task&.stop
    @server_task = nil
    @sessions.each(&:close)
    @sessions = []
    @bound&.close
    @bound = nil
    end

    private

    def build_app
    lambda do |request|
      @handshakes << {
        authorization: request.headers["authorization"],
        protocols: Array(request.headers["sec-websocket-protocol"]),
        origin: Array(request.headers["origin"]).first,
        path: request.path,
      }
      response = Async::WebSocket::Adapters::HTTP.open(request, protocols: [PROTOCOL]) do |connection|
        session = CableSession.new(connection)
        @sessions << session
        @behavior.call(session)
      end
      response || ::Protocol::HTTP::Response[400, {}, ["not a websocket handshake"]]
    end
    end
  end

  # The server side of one websocket, speaking the ActionCable frame
  # vocabulary. Passed to the FakeCableServer behavior block.
  class CableSession
    def initialize(connection)
    @connection = connection
    end

    def welcome
    send_frame({ type: "welcome" })
    end

    def ping(epoch = Time.now.to_i)
    send_frame({ type: "ping", message: epoch })
    end

    def confirm(identifier)
    send_frame({ identifier:, type: "confirm_subscription" })
    end

    def reject(identifier)
    send_frame({ identifier:, type: "reject_subscription" })
    end

    def broadcast(identifier, message)
    send_frame({ identifier:, message: })
    end

    def disconnect(reason:, reconnect: false)
    send_frame({ type: "disconnect", reason:, reconnect: })
    end

    # The next parsed client command ({"command" => ..., "identifier" => ...});
    # nil once the client is gone.
    def read_command
    message = @connection.read
    message && JSON.parse(message.to_str)
    rescue StandardError
    nil
    end

    # Block until the client goes away, discarding further commands. Keeps
    # the connection open while the client side drives the scenario.
    def drain
    while read_command
    end
    end

    def close
    @connection.close
    rescue StandardError
    nil
    end

    private

    def send_frame(hash)
    @connection.write(JSON.generate(hash))
    @connection.flush
    end
  end
end
