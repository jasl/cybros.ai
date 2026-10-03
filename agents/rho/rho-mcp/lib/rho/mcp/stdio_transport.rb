require "mcp"
require "rho/runner"

module Rho
  module Mcp
    # THE SDK'S STDIO TRANSPORT, RE-PARENTED. The gem's
    # `MCP::Client::Stdio#start` spawns through `Open3.popen3` with no
    # process group, MERGES its `env` onto this process's environment, and
    # closes by signalling the leader's pid alone — a server that forked
    # (an `npx` shim in front of `node`) would outlive its leader, and
    # rho's own credentials would ride into a third party's process. Four
    # members are overridden — the whole set that touches `@wait_thread`,
    # `@stderr_thread` or respawns — and the rest of the SDK (the
    # handshake, the modern probe, the framed reads, the ping answer) is
    # used as it is; the four names are the coupling pinned to `mcp ~> 1.6.0`:
    #
    # - `start`: the child through the runner's `OwnedProcess` (its own
    #   GROUP, the `true(1)` guard reserving the pgid), `unsetenv_others:
    #   true` so the scrubbed `env` REPLACES the environment, `chdir:` the
    #   row's `cwd`, a stderr tail of 4 KiB kept (the browser Driver's
    #   `STDERR_KEEP_BYTES`; `force_encoding(UTF_8).scrub` on read — the
    #   ledger's StringIO-under-US-ASCII trap), and a WATCHER thread that
    #   records the exit status the moment the leader is gone;
    # - `close`: the spec's shutdown ladder to the GROUP — close stdin,
    #   wait; TERM, wait; KILL and reap — each stage bounded by
    #   `STOP_STAGE_SECONDS`, the last word in an `ensure`;
    # - `ensure_running!`: the exit record, not a thread's liveness;
    # - `send_notification`: a NO-OP once the process is gone — the SDK's
    #   would `start` and `connect` again to deliver a `notifications/
    #   cancelled` fired after the server died (the cancel thread runs
    #   after the worker returned), respawning the server outside
    #   `Rho::Mcp`'s book-keeping; the spec says a cancellation references
    #   only a request believed still in progress.
    #
    # `read_timeout=` is the startup bound's toggle: set for the connect
    # and the lists, CLEARED after (the SDK's own probe pattern), or a
    # per-frame read bound would turn a long call into "Timed out waiting
    # for server response" → `failed` instead of the clamp's answer.
    class StdioTransport < MCP::Client::Stdio
      STDERR_KEEP_BYTES = 4096
      STOP_STAGE_SECONDS = 3.0
      POLL_SECONDS = 0.02

      attr_reader :exit_status, :exited_at, :cwd
      attr_writer :read_timeout

      def initialize(command:, args: [], env: {}, cwd: Dir.pwd, read_timeout: nil, stop_stage: STOP_STAGE_SECONDS,
                     clock: -> { Time.now })
        super(command: command, args: args, env: env, read_timeout: read_timeout)
        @cwd = cwd
        @stop_stage = stop_stage
        @clock = clock
        @process = nil
        @watcher = nil
        @exit_status = nil
        @exited_at = nil
        @tail = +""
        @tail_lock = Mutex.new
      end

      def read_timeout = @read_timeout

      def pid = @process&.pid

      def group_pid = @process&.group_pid

      def exited? = !@exit_status.nil?

      # "status 3" / "signal 9" / "status unknown": the exit as a sentence names it.
      def exit_description
        status = @exit_status
        return "status unknown" unless status.respond_to?(:exitstatus)

        status.signaled? ? "signal #{status.termsig}" : "status #{status.exitstatus}"
      end

      def stderr_tail
        @tail_lock.synchronize { @tail.dup.force_encoding(Encoding::UTF_8).scrub }
      end

      # After a death: let the watcher record the exit and the stderr
      # drain reach its EOF, each within the bound, so the sentence built
      # next quotes the last thing the server said rather than racing it.
      def settle(seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        sleep POLL_SECONDS while !exited? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @stderr_thread&.join([remaining, 0.05].max) if exited?
        exited?
      end

      def start
        raise "MCP::Client::Stdio already started" if @started

        stdin_r, stdin_w = IO.pipe
        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe
        begin
          @process = Rho::Runner::OwnedProcess.spawn(
            @env || {}, @command, *@args,
            chdir: @cwd, in: stdin_r, out: stdout_w, err: stderr_w, unsetenv_others: true
          )
        rescue Errno::ENOENT, Errno::EACCES, Errno::ENOEXEC, Errno::ENOTDIR => error
          [stdin_r, stdin_w, stdout_r, stdout_w, stderr_r, stderr_w].each(&:close)
          raise MCP::Client::RequestHandlerError.new(
            "Failed to spawn server process: #{error.message}", {}, error_type: :internal_error, original_error: error
          )
        ensure
          [stdin_r, stdout_w, stderr_w].each { |io| io.close unless io.closed? }
        end
        @stdin = stdin_w
        @stdout = stdout_r
        @stderr = stderr_r
        @stdout.set_encoding("UTF-8")
        @stdin.set_encoding("UTF-8")
        @stderr_thread = Thread.new { drain_stderr(stderr_r) }
        @stderr_thread.name = "rho-mcp-stderr-#{@process.pid}"
        @wait_thread = @watcher = Thread.new { watch_exit(@process) }
        @watcher.name = "rho-mcp-watcher-#{@process.pid}"
        @started = true
      end

      # THE LADDER (stdio.mdx "Shutdown"): close stdin and wait for the
      # server to leave on its own; TERM the group and wait; KILL the group
      # and reap it — the `OwnedProcess` reaps the leader AND the guard, so
      # the pgid is released only when nothing holds it. Idempotent; a
      # no-op when nothing was ever started.
      def close
        return unless @started

        stage { @stdin.close unless @stdin.closed? }
        @process.terminate("TERM") unless exited_within(@stop_stage)
        exited_within(@stop_stage)
      ensure
        release if @started
      end

      # THE POISON RULE'S TEARDOWN — `bash`'s own cancel precedent: KILL
      # the group and reap it, no graceful stage. A server whose call was
      # cancelled or clamped is wedged by the SDK's own reader design (the
      # abandoned read eats the next frame) and its state is lost either
      # way; the runner's clamp gives the handler `Pool::CANCELLATION_GRACE_
      # SECONDS` (2 s) to return, and the park's headroom is smaller still,
      # so a stdin-close wait or a TERM wait here would leave the claim to
      # the sweep's `uncertain` — the word for a runner that died. The
      # ladder is `close`'s, for shutdown.
      def kill
        return unless @started

        begin
          @process.kill_and_reap
        rescue StandardError
          nil
        end
      ensure
        release if @started
      end

      def send_notification(notification:)
        return nil unless @started && !exited? && connected?

        @write_mutex.synchronize { write_message(notification) }
        nil
      rescue MCP::Client::RequestHandlerError
        nil
      end

      private

        def ensure_running!
          return if @started && !exited?

          raise MCP::Client::RequestHandlerError.new("Server process has exited", {}, error_type: :internal_error)
        end

        # The last word of both teardowns: the guard reaped (idempotent),
        # the watcher and the drain joined briefly, the pipes closed, the
        # SDK's flags reset so `connected?` answers false.
        def release
          begin
            @process.kill_and_reap
          rescue StandardError
            nil
          end
          @watcher&.join(0.5)
          [@stdout, @stderr].each { |io| stage { io.close unless io.closed? } }
          @stderr_thread&.join(0.5)
          @started = false
          @initialized = false
          @server_info = nil
          leave_modern_mode
        end

        # Reads what is there, ends at EOF, keeps the last 4 KiB.
        def drain_stderr(io)
          while (chunk = io.readpartial(STDERR_KEEP_BYTES))
            @tail_lock.synchronize do
              @tail << chunk
              overflow = @tail.bytesize - STDERR_KEEP_BYTES
              @tail = @tail.byteslice(overflow..) if overflow.positive?
            end
          end
        rescue EOFError, IOError
          nil
        end

        # THE WATCHER: joins the leader and records the exit the moment it
        # is gone, so a server that died between calls is known BEFORE the
        # next call reads a closed pipe.
        def watch_exit(process)
          status = process.wait(check_cancellation: false)
          @exited_at = @clock.call
          @exit_status = status || :unknown
        rescue StandardError
          @exited_at = @clock.call
          @exit_status = :unknown
        end

        def exited_within(seconds)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
          until exited? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            sleep POLL_SECONDS
          end
          exited?
        end

        def stage
          Timeout.timeout(@stop_stage) { yield }
        rescue Timeout::Error, StandardError
          nil
        end
    end
  end
end
