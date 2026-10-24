require "socket"
require_relative "../process_registry"

module E2E
  module McpFixture
    # The caller's E2E bundle owns this standalone fixture process.
    module Host
      FIXTURE = File.expand_path("server.rb", __dir__)
      READY_SECONDS = 30
      POLL = 0.1

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
          Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", FIXTURE, entry, port.to_s,
          chdir: File.dirname(__dir__), out: [log, "a"], err: [log, "a"], pgroup: true
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
