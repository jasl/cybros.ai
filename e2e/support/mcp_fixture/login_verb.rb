require "tempfile"
require_relative "../process_registry"
require_relative "../rho_daemon"

module E2E
  module McpFixture
    # `rho mcp login` AS A BOUNDED CHILD: the shipped binary under rho's bundle and the journey's
    # home, in its own process group through `E2E::ProcessRegistry`, its stdout and stderr CAPTURED
    # APART (the lines are pinned on stdout; both are kept for the token-free negative) and its
    # stdin NEVER the harness's terminal — `File::NULL` when the stub browser drives the login, or a
    # pipe the journey writes ONE line into when it plays the person pasting the redirect under
    # `--no-browser` (a child in its own group that touches the terminal is stopped by SIGTTIN, the
    # box's freeze). The wait is bounded from THIS side: a login that has not exited inside SECONDS
    # is terminated with its group and answered `timed_out`, so a red login flunks with the output
    # it printed instead of spending the world's deadline — the verb's own five-minute callback wait
    # is the product's, never the harness's.
    module LoginVerb
      SECONDS = 60
      POLL = 0.05
      DRAIN_JOIN_SECONDS = 2
      URL_LINE = /\Aopen this URL to authorize rho: (\S+)/

      Result = Data.define(:output, :errors, :status, :timed_out)

      # The journey's side of a paste: stdout lines popped with the run's
      # own deadline, one line written back and stdin closed.
      Session = Data.define(:lines, :stdin_writer, :deadline) do
        # The next stdout line, or nil at EOF or the deadline.
        def next_line = lines.pop(timeout: [deadline - LoginVerb.monotonic, 0].max)

        # The URL rho printed, or nil when the verb ended (or hung) first.
        def url
          while (line = next_line)
            url = line[URL_LINE, 1]
            return url if url
          end
          nil
        end

        def paste(line)
          stdin_writer.puts(line) if line
          stdin_writer.close
        end
      end

      module_function

      # `args` after `exe/rho`; `env` is merged UNDER the bundle pins and
      # the home (a nil value unsets — `"BROWSER" => nil`). With a block
      # the child's stdin is a pipe and the block is handed a Session.
      def run(args, env:, home:, nexus_url:, seconds: SECONDS)
        deadline = monotonic + seconds
        output = +""
        lines = Thread::Queue.new
        errors = Tempfile.new("rho-mcp-login-stderr")
        stdout_reader, stdout_writer = IO.pipe
        stdin_reader, stdin_writer = block_given? ? IO.pipe : [File::NULL, nil]
        pid = ProcessRegistry.spawn(
          child_env(env, home), *command(args, nexus_url),
          chdir: RhoDaemon::RHO_ROOT, in: stdin_reader, out: stdout_writer, err: errors.path, pgroup: true
        )
        stdout_writer.close
        stdin_reader.close if stdin_writer
        drain = Thread.new { drain(stdout_reader, output, lines) }
        status = nil
        timed_out = false
        begin
          yield Session.new(lines: lines, stdin_writer: stdin_writer, deadline: deadline) if block_given?
          status, timed_out = wait(pid, deadline)
        ensure
          ProcessRegistry.terminate(pid) if status.nil? && !timed_out
          stdin_writer&.close unless stdin_writer&.closed?
          drain.join(DRAIN_JOIN_SECONDS)
          stdout_reader.close unless stdout_reader.closed?
        end
        Result.new(output: output.force_encoding(Encoding::UTF_8).scrub, errors: read(errors), status: status, timed_out: timed_out)
      end

      def child_env(env, home)
        env.merge(RhoDaemon::CHILD_BUNDLE_ENV).merge(RhoDaemon::CHILD_DEV_ENV).merge("RHO_HOME" => home)
      end

      def command(args, nexus_url)
        [Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", "exe/rho", *args, "--nexus-url", nexus_url]
      end

      # Every stdout line into the buffer and the queue; the queue closed
      # at EOF (or when the reader is closed under it), so a pop answers nil.
      def drain(io, output, lines)
        io.each_line do |line|
          output << line
          lines << line
        end
      rescue IOError
        nil
      ensure
        lines.close
      end

      # `[status, timed_out]`: the child reaped, or its group terminated
      # at the deadline.
      def wait(pid, deadline)
        loop do
          _pid, status = Process.wait2(pid, Process::WNOHANG)
          if status
            ProcessRegistry.unregister(pid)
            return [status, false]
          end
          if monotonic > deadline
            ProcessRegistry.terminate(pid)
            return [nil, true]
          end

          sleep POLL
        end
      end

      def read(file)
        file.rewind
        file.read.to_s.force_encoding(Encoding::UTF_8).scrub
      ensure
        file.close!
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
