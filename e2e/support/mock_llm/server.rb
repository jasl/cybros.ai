require "puma"
require "puma/log_writer"
require "socket"
require_relative "app"

module E2E
  module MockLLM
    # THE FAKE PROVIDER, LISTENING.
    #
    # `MockLLM::App` is a Rack app and until now nothing ever bound it to a
    # port: the harness drove it in memory and Nexus — a separate process —
    # had no way to reach it at all. This is the piece that was owed.
    #
    # IN-PROCESS, not a subprocess, and deliberately. The mock needs to be
    # reachable over TCP by Nexus, which a listener in the harness process
    # satisfies exactly as well as a child would; and it has to be listening
    # BEFORE Nexus boots, because the catalog fragment that points the dev
    # lane at it carries the port. A child process would add a spawn, a
    # readiness poll and a reaping path to buy nothing. Puma's own threads do
    # the serving, so the harness thread is free to drive the journey.
    #
    # THE PORT IS THE SERVER'S TO CHOOSE. It binds `:0` and reports what the
    # kernel gave it, rather than taking a port from a caller who would have
    # to guess one — which is also why `base_url` is only meaningful after
    # `start`.
    class Server
      # The directive grammar's slow ceiling. A journey that wants to observe
      # an in-flight call raises it; every other journey wants it small so a
      # scripted delay cannot dominate the run deadline.
      DEFAULT_MAX_SLOW_SECONDS = 0.2

      attr_reader :port

      def initialize(max_slow_seconds: DEFAULT_MAX_SLOW_SECONDS)
        @app = App.new(max_slow_seconds: max_slow_seconds)
        @server = nil
        @port = nil
      end

      def start
        raise "already started" unless @server.nil?

        # Silent by default: the fake's request log is noise in a journey's
        # output, and a failure shows up either as a failed assertion or as a
        # Nexus-side provider error, both of which say more.
        @server = Puma::Server.new(
          @app, Puma::Events.new,
          { min_threads: 0, max_threads: 4, log_writer: Puma::LogWriter.strings }
        )
        @port = @server.add_tcp_listener("127.0.0.1", 0).addr[1]
        @server.run
        self
      end

      # Only after `start`: before it there is no port, and a base_url built
      # from a port nobody bound is the kind of value that reaches a config
      # file and fails somewhere else.
      def base_url
        raise "the mock provider has not started" if @port.nil?

        "http://127.0.0.1:#{@port}"
      end

      def stop
        return if @server.nil?

        @server.stop(true)
        @server = nil
        @port = nil
      end
    end
  end
end
