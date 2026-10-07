$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rho/web-tools"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "minitest/autorun"
require_relative "support/fixture_app"

module WebToolsTest
  # THE TOOLS' EXECUTION ENVIRONMENT, over a throwaway root, with a context
  # bound for the block the way the pool binds one on a worker — the tool
  # checks cancellation at its own checkpoints and reads it off the thread.
  module Helpers
    def with_tool_env
      Dir.mktmpdir("rho-web-tools-test") do |root|
        real = File.realpath(root)
        env = Rho::Runner::ToolEnv.new(root: real, artifacts_dir: File.join(real, ".artifacts"))
        Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) { yield(env, real) }
      end
    end

    # Puma on a loopback port of the OS's choosing, quiet; the base URL.
    # Two calls are two "sites": `127.0.0.1:A` and `127.0.0.1:B` differ in
    # port, so `same_site?` halts between them.
    def serve(app)
      server = Puma::Server.new(app, nil, min_threads: 0, max_threads: 8, log_writer: Puma::LogWriter.null)
      server.add_tcp_listener("127.0.0.1", 0)
      server.run
      (@servers ||= []) << server
      "http://127.0.0.1:#{server.connected_ports.fetch(0)}"
    end

    def halt_servers
      Array(@servers).each { |server| server.halt(true) rescue nil }
      @servers = []
    end

    # A logger that keeps every line: `[level, event, fields]`.
    def recording_log
      lines = []
      logger = Object.new
      %i[debug info warn error].each do |level|
        logger.define_singleton_method(level) { |event, **fields| lines << [level, event, fields] }
      end
      logger.define_singleton_method(:lines) { lines }
      logger
    end

    def elapsed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end
  end
end
