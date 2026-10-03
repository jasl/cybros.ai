require "timeout"

module Rho
  module Browser
    # THE PLAYWRIGHT HALF, and the only file that knows the gem exists. It
    # answers one page and can stop; everything above it talks to a page
    # and never to Playwright, which is what lets a fake stand in for the
    # whole thing under test.
    #
    # `require "playwright"` happens at START, not at load. The extension
    # must register — and the daemon must boot — on a machine where the
    # Node driver is not installed yet; the tools then report exactly what
    # is missing at the moment a model first reaches for a page, which is
    # a message somebody will read, instead of a daemon that will not
    # start with a stack trace nobody asked for.
    #
    # BOUNDED IN BOTH DIRECTIONS, TOLD WHEN THE PROCESS DIES, AND ABLE TO
    # END IT WITHOUT ITS HELP. Three things the gem does not do, each
    # found by a review against its source:
    #
    # - It never signals a driver that EXITED. Its stdout reader ends
    #   silently at EOF and its cleanup fires only on IOError, so a pending
    #   promise waits forever and a driver that died in its first second
    #   (npx offline, a shim that cannot find node) read as a sixty-second
    #   hang with the real reason lost. A watcher thread joins the child
    #   and rejects every pending promise the moment it is gone.
    # - Its stderr reader spins at 100% CPU once the child exits, because
    #   `IO#read` answers "" at EOF and "" is truthy. A transport subclass
    #   reads with `readpartial`, ends at EOF, and keeps the last few KB so
    #   the exit can name its cause.
    # - Its start and its graceful stop both wait on a promise the driver
    #   must answer. So a start has a deadline, and a stop asks nicely,
    #   then closes the pipes, then SIGTERMs the process group — which
    #   matters, because Playwright launches Chromium DETACHED: a killed
    #   driver cannot take its browser with it, but a TERMed one runs its
    #   exit handlers and does. SIGKILL is the last word, and the one
    #   case that can orphan a Chromium; it is logged as such.
    class Driver
      # `playwright` on PATH is what `npm i -g playwright` leaves behind.
      # The Ruby client tracks the driver's protocol release for release,
      # so a machine whose global install has drifted names a pinned one
      # here — `npx -y playwright-core@1.62.1` is a valid value, because
      # the transport hands the string to a shell.
      ENV_KEY = "RHO_BROWSER_PLAYWRIGHT_CLI".freeze
      DEFAULT_CLI = "playwright".freeze

      # A cold `npx` fetch is the slow legitimate case; a driver that never
      # speaks is the case this bounds. Sixty seconds is generous for the
      # first and decisive for the second.
      START_DEADLINE_SECONDS = 60.0
      # How long each stage of a stop may take before the next, harder one.
      STOP_STAGE_SECONDS = 3.0
      INSTALL_HINT = "install with `npm i -g playwright && playwright install chromium`, " \
                     "or name a driver in #{ENV_KEY}".freeze
      # THE INSTALLED DRIVER: a dev-profile prefix
      # carries `bin/rho-playwright` — Node + playwright-core pinned to this
      # gem's version, the browsers dir scoped inside that script. Read here,
      # at the spawn site, from the prefix the wrapper exported: nothing
      # Playwright-specific is in rho's environment for a tool child to
      # inherit (a project's own `npx playwright` never sees rho's browsers).
      PREFIX_ENV = "RHO_PREFIX".freeze
      PREFIX_CLI = %w[bin rho-playwright].freeze

      # Every way a driver can fail, under one class so a tool reports the
      # message and nothing else. The message is written for the model.
      class Failure < Rho::Runner::Error; end
      class StartTimedOut < Failure; end
      class Exited < Failure; end
      class Missing < Failure; end

      # A TRANSPORT THAT DOES NOT SPIN AND REMEMBERS WHAT THE DRIVER SAID.
      # The gem's reader is `while err = @stderr.read` — "" at EOF, forever.
      # This one reads what is there, ends at EOF, and keeps a tail so a
      # driver that exits can be quoted. It still forwards to $stderr, so
      # the daemon's log sees what it always saw.
      #
      # BUILT ON FIRST USE, not at load: naming `Playwright::Transport` in
      # a class definition would require the gem when this file is read,
      # and the whole point of the lazy require is that the extension
      # loads on a machine where the driver is not installed yet.
      STDERR_KEEP_BYTES = 4096
      CRASH_MARKER = "undefined:1".freeze

      class << self
        def quiet_transport
          @quiet_transport ||= Class.new(::Playwright::Transport) do
            def initialize(**)
              super
              @captured = +""
              @captured_lock = Mutex.new
            end

            def stderr_tail
              @captured_lock.synchronize { @captured.dup.force_encoding(Encoding::UTF_8).scrub }
            end

            def waiter = @thread

            private

              def handle_stderr
                while (chunk = @stderr.readpartial(4096))
                  @captured_lock.synchronize do
                    @captured << chunk
                    overflow = @captured.bytesize - Driver::STDERR_KEEP_BYTES
                    @captured = @captured.byteslice(overflow..) if overflow.positive?
                  end
                  if chunk.include?(Driver::CRASH_MARKER)
                    @on_driver_crashed&.call
                    break
                  end
                  $stderr.write(chunk)
                end
              rescue EOFError, IOError
                @on_driver_closed&.call
              end
          end
        end
      end

      # `RHO_BROWSER_PLAYWRIGHT_CLI` first (an operator's word), then the
      # prefix's `bin/rho-playwright` when it is there, then `playwright`
      # on PATH.
      def self.default_cli(env = ENV)
        named = env[ENV_KEY].to_s
        return named unless named.empty?

        prefix = env[PREFIX_ENV].to_s
        unless prefix.empty?
          installed = File.join(File.expand_path(prefix), *PREFIX_CLI)
          return installed if File.executable?(installed)
        end
        DEFAULT_CLI
      end

      def initialize(cli: nil, headless: true, start_deadline: START_DEADLINE_SECONDS,
                     stop_stage: STOP_STAGE_SECONDS, log: nil)
        @cli = cli || self.class.default_cli
        @headless = headless
        @start_deadline = start_deadline
        @stop_stage = stop_stage
        @log = log
        clear
      end

      def started? = !@transport.nil?

      # A tab. Raises if the driver is not started; the session starts it
      # first and this is never reached otherwise.
      def new_page
        raise Failure, "the browser is not started" if @context.nil?

        @context.new_page
      end

      def open_pages = @context&.pages || []

      # Alive means the process is AND the browser is still on the other
      # end of it. The OOM killer takes Chromium, the largest thing on the
      # machine, and leaves node; a liveness that only watched the process
      # would keep handing out tabs from a browser that no longer exists.
      def alive?
        return false unless started? && @exited.nil?

        !@browser.respond_to?(:connected?) || @browser.connected?
      rescue StandardError
        false
      end

      # A fresh page in a fresh context. NEVER TWO: a start over a live
      # driver stops it first. Raises a Failure the model can read when it
      # cannot start, and leaves nothing behind when it does — including
      # when it never finishes.
      #
      # THE GEM'S `Playwright.create` IS NOT USED. It spawns the driver,
      # waits on its first answer with no clock, and keeps the transport in
      # a local, so a start cut by a deadline had a live process nothing
      # held. The same steps are taken here with the transport held from
      # the first one.
      def start
        require "playwright"
        stop
        Timeout.timeout(@start_deadline) do
          @transport = self.class.quiet_transport.new(playwright_cli_executable_path: @cli)
          connection = ::Playwright::Connection.new(@transport)
          connection.async_run
          @connection = connection
          watch_exit(connection)
          playwright = connection.initialize_playwright
          @execution = ::Playwright::Execution.new(connection, ::Playwright::PlaywrightApi.wrap(playwright))
          @browser = @execution.playwright.chromium.launch(headless: @headless)
          # ONE CONTEXT, SHARED: a login made in one loop's tab is a login
          # for every loop — the way every reference works, and the only
          # "log in once" mechanism there is.
          @context = @browser.new_context
        end
        self
      rescue Errno::ENOENT
        stop
        raise Missing, "the Playwright driver (#{@cli}) is not installed or not on PATH; #{INSTALL_HINT}"
      rescue Timeout::Error
        stop
        raise StartTimedOut,
          "the browser driver (#{@cli}) did not start within #{@start_deadline}s"
      rescue StandardError => error
        # THE EXIT MAY BE KNOWN A BEAT LATER THAN THE FAILURE. The gem's own
        # closed hook fires at stderr EOF and rejects the promise before
        # the child has been reaped, so the watcher that records WHY may
        # still be a few milliseconds behind the error it caused. Give it
        # that moment; a driver that merely misbehaved leaves @exited nil
        # and its own error stands.
        @watcher&.join(1.0) if @exited.nil?
        exited = @exited
        tail = @transport&.stderr_tail.to_s.strip
        stop
        raise exited_failure(exited, tail) if exited

        raise error
      end

      # FIVE STAGES, EACH ON A CLOCK, EACH SURVIVING THE LAST ONE'S FAILURE,
      # AND THE LAST WORD IN AN ENSURE. Graceful close for a healthy
      # browser; stopping the connection closes the pipes and a healthy
      # driver exits on that, killing its browser on the way out; SIGTERM
      # for one that does not, which still runs its exit handlers; SIGKILL
      # for one that ignores even that. The ensure re-checks and kills,
      # because an OUTER clock may unwind this method between stages, and
      # a live process with no handle is the one thing this must never
      # leave. Idempotent, and a no-op when nothing was ever started.
      def stop
        return unless started?

        stage { @browser&.close }
        stage { @execution&.stop || @connection&.stop }
        signal("TERM") unless exited_within(@stop_stage)
        signal("KILL") unless exited_within(@stop_stage)
      ensure
        if started? && process_alive?
          @log&.warn("browser_driver_killed", detail: "the driver ignored SIGTERM; its browser may be orphaned")
          signal("KILL")
        end
        @watcher&.join(0.2)
        clear
      end

      private

        def clear
          @transport = nil
          @connection = nil
          @execution = nil
          @browser = nil
          @context = nil
          @watcher = nil
          @exited = nil
        end

        # THE WATCHER: the exit signal the gem does not give. Joins the
        # child; when it is gone, rejects every pending promise with the
        # reason and closes the pipes so the reader threads end too.
        def watch_exit(connection)
          waiter = @transport.waiter
          return if waiter.nil?

          transport = @transport
          @watcher = Thread.new do
            status = begin
              waiter.value
            rescue StandardError
              nil
            end
            @exited = status || :unknown
            connection.cleanup(cause: "the browser driver exited (#{describe(status)})")
            begin
              transport.stop
            rescue StandardError
              nil
            end
          end
          @watcher.name = "rho-browser-driver-watcher"
        end

        def exited_failure(status, tail)
          quoted = tail.empty? ? "" : "; it said: #{tail}"
          Exited.new("the browser driver (#{@cli}) exited during start (#{describe(status)})#{quoted}")
        end

        def describe(status)
          return "status unknown" unless status.respond_to?(:exitstatus)

          status.signaled? ? "signal #{status.termsig}" : "status #{status.exitstatus}"
        end

        def stage
          Timeout.timeout(@stop_stage) { yield }
        rescue Timeout::Error, StandardError
          nil
        end

        # LIVENESS IS THE WAITER THREAD, never `kill(0, pid)`: once the
        # child has been reaped its pid is free, and a check that says
        # "alive" through pid reuse would SIGKILL somebody else.
        def process_alive?
          @transport&.waiter&.alive? || false
        rescue StandardError
          false
        end

        def exited_within(seconds)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
          until !process_alive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            sleep 0.02
          end
          !process_alive?
        end

        def driver_pid
          @transport&.waiter&.pid
        rescue StandardError
          nil
        end

        # The whole group first — the driver spawns with pgroup: true, so
        # its pgid is its pid — then the pid alone.
        def signal(name)
          pid = driver_pid
          return if pid.nil? || !process_alive?

          Process.kill(name, -pid)
        rescue Errno::ESRCH, Errno::EPERM
          begin
            Process.kill(name, pid)
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end
        end
    end
  end
end
