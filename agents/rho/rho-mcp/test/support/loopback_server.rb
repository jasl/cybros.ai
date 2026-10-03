require "puma"
require "puma/server"
require "puma/log_writer"
require "rack"

module McpTest
  # ONE LOOPBACK HTTP SERVER FOR THE SUITE: puma on a port of the OS's
  # choosing, quiet, halted by the test's teardown.
  module LoopbackServer
    module_function

    # Answers `[server, base]` — the base `http://127.0.0.1:PORT`.
    def start(app)
      server = Puma::Server.new(app, nil, min_threads: 0, max_threads: 8, log_writer: Puma::LogWriter.null)
      server.add_tcp_listener("127.0.0.1", 0)
      server.run
      [server, "http://127.0.0.1:#{server.connected_ports.fetch(0)}"]
    end

    def stop(server)
      server.halt(true)
    rescue StandardError
      nil
    end
  end
end
