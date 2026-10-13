require "socket"
require_relative "../process_registry"

module E2E
  module McpFixture
    # THE FIXTURE PROCESS: `server.rb ENTRY PORT` under puma on a loopback port the journey picks,
    # spawned in its own group under rho-mcp's bundle (puma is its development dependency; e2e's
    # Gemfile is unchanged — on a box that means rho-mcp's dev bundle is installed) through
    # `E2E::ProcessRegistry`, so the registry's drain leaves nothing behind on a red run. Shared by
    # the `http` entry (mcp_tools) and the `oauth` entry (mcp_oauth): the port is picked
    # bind-then-close, the process is ready once the port answers, and its log is read by UTF-8
    # name.
    module Host
      RHO_MCP_ROOT = File.expand_path("../../../agents/rho/rho-mcp", __dir__)
      FIXTURE = File.expand_path("server.rb", __dir__)
      READY_SECONDS = 30
      POLL = 0.1
      BUNDLE_ENV = {
        "BUNDLE_GEMFILE" => File.join(RHO_MCP_ROOT, "Gemfile"),
        "BUNDLE_LOCKFILE" => File.join(RHO_MCP_ROOT, "Gemfile.lock"),
        "BUNDLE_FROZEN" => "true",
      }.freeze

      # The port never answered inside READY_SECONDS; the message carries
      # the fixture's own log, so the caller's flunk names the cause.
      class NotListening < StandardError; end

      module_function

      def free_port
        server = TCPServer.new("127.0.0.1", 0)
        server.addr.fetch(1)
      ensure
        server&.close
      end

      # The pid of the fixture's process group; the journey owns its stop.
      def spawn(entry:, port:, log:)
        ProcessRegistry.spawn(
          BUNDLE_ENV, Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", FIXTURE, entry, port.to_s,
          chdir: RHO_MCP_ROOT, out: [log, "a"], err: [log, "a"], pgroup: true
        )
      end

      def await_ready!(port, log:, seconds: READY_SECONDS)
        deadline = monotonic + seconds
        loop do
          TCPSocket.new("127.0.0.1", port).close
          return port
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET
          raise NotListening, "the fixture never listened on 127.0.0.1:#{port} within #{seconds} s:\n#{log_text(log)}" if monotonic > deadline

          sleep POLL
        end
      end

      def stop(pid)
        ProcessRegistry.terminate(pid)
      rescue StandardError => error
        warn "Could not stop the fixture process #{pid}: #{error.class}: #{error.message}"
      end

      def log_text(log)
        File.file?(log) ? File.read(log, encoding: Encoding::UTF_8).scrub : ""
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
