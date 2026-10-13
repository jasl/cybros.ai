module Rho
  class Runner
    module Checkpoints
      # ONE GIT CALL AGAINST THE SHADOW STORE, in its own process group,
      # under a deadline, with the user's git neutralised.
      #
      # THE PROCESS GROUP IS THE UNIT (memory): every call is spawned
      # through `OwnedProcess`, so a call that overruns its deadline is
      # killed as a GROUP — `gc`'s repack children, a stray helper — and
      # reaped, never left behind holding a pipe. `core.fsmonitor=false`
      # and `gc.auto=0` (set by the store at open) are what keep every
      # process git starts INSIDE that group: the fsmonitor daemon and an
      # auto-gc both detach, and a detached child is one no kill reaches.
      #
      # THE ENVIRONMENT IS OURS, NOT THE USER'S (hermes's list):
      # the five redirecting variables are dropped and re-set to the
      # store's own (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`), the
      # global and system configs are hidden (`GIT_CONFIG_GLOBAL=/dev/null`,
      # `GIT_CONFIG_NOSYSTEM=1`) so a `core.excludesFile` or a `core.hooksPath`
      # in `~/.gitconfig` never shapes a capture, and `HOME` and
      # `GIT_EXEC_PATH` are KEPT: a relocated git must still find its
      # helpers. The child's base is `ChildEnv`'s — unbundled, the locale
      # re-applied — as every spawn site's is.
      #
      # A DEADLINE, NEVER A STALL: `deadline` is a monotonic instant the
      # whole operation shares (a capture's every call counts against ONE
      # thirty seconds), so a call past it is killed and `TimedOut` raised;
      # the store turns that into `checkpoint_skipped {reason: timeout}`.
      class Git
        # git exited non-zero: the arguments and the stderr tail travel so
        # the store can say WHICH call failed and why.
        class Failed < Error
          attr_reader :arguments, :status, :stderr

          def initialize(arguments, status, stderr)
            @arguments = arguments
            @status = status
            @stderr = stderr
            super("git #{arguments.first} exited #{status.exitstatus.inspect}: #{stderr.to_s.strip}")
          end
        end

        # The wall clock passed while git ran; the group is dead.
        class TimedOut < Error
          attr_reader :arguments

          def initialize(arguments)
            @arguments = arguments
            super("git #{arguments.first} exceeded the wall clock and its process group was killed")
          end
        end

        Outcome = Data.define(:stdout, :stderr, :status) do
          def ok? = status.success?
        end

        # The five that redirect a git command somewhere else (hermes
        # `checkpoint_manager.py:57`): dropped from the inherited
        # environment, three of them re-set to ours.
        DROPPED = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_NAMESPACE GIT_ALTERNATE_OBJECT_DIRECTORIES].freeze
        # ONE FIXED IDENTITY on every record: the store is the runner's,
        # never a person's, and a commit-tree with no identity would read
        # the user's `~/.gitconfig` — hidden — and then fail.
        IDENTITY = {
          "GIT_AUTHOR_NAME" => "rho", "GIT_AUTHOR_EMAIL" => "rho@localhost",
          "GIT_COMMITTER_NAME" => "rho", "GIT_COMMITTER_EMAIL" => "rho@localhost",
        }.freeze
        NEUTRAL = {
          "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0",
        }.freeze
        POLL_SECONDS = 0.01
        # How long a reader is given to drain a dead group's pipe before the
        # read end is closed under it — a process outside the group holding
        # the write end is the one shape that could hold a reader forever.
        DRAIN_SECONDS = 1.0

        attr_reader :binary, :git_dir, :work_tree

        def initialize(binary:, git_dir:, work_tree:, clock: nil)
          @binary = binary
          @git_dir = git_dir
          @work_tree = work_tree
          @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        end

        # The call's stdout, or `Failed` on a non-zero exit — for every call
        # whose failure is the operation's failure.
        def read(*arguments, deadline:, stdin: nil, index: nil, redirect: true)
          outcome = call(*arguments, deadline: deadline, stdin: stdin, index: index, redirect: redirect)
          raise Failed.new(arguments, outcome.status, outcome.stderr) unless outcome.ok?

          outcome.stdout
        end

        # The outcome whatever the exit — for a call whose non-zero exit is
        # an ANSWER (`cat-file -t` on an unknown hash, a create-only
        # `update-ref` that met an existing ref). `TimedOut` still raises.
        # `index:` names a temporary index file instead of the store's;
        # `redirect: false` runs git with NO store variables at all — the
        # one read of the PROJECT's own checkout the store makes at open.
        def call(*arguments, deadline:, stdin: nil, index: nil, redirect: true)
          # A cancelled task spawns nothing: the check runs BEFORE the
          # spawn (and before every poll), so a cancellation is always its
          # own exception and never a killed git read as `git_failed`.
          ExecutionContext.current&.raise_if_cancelled!
          raise TimedOut, arguments if @clock.call >= deadline

          in_r, in_w = IO.pipe
          out_r, out_w = IO.pipe
          err_r, err_w = IO.pipe
          process = nil
          settled = false
          process = OwnedProcess.spawn(
            environment(index: index, redirect: redirect), @binary, *arguments.map(&:to_s),
            chdir: @work_tree, in: in_r, out: out_w, err: err_w, unsetenv_others: true
          )
          [in_r, out_w, err_w].each(&:close)
          feeder = feed(in_w, stdin)
          stdout = drain(out_r)
          stderr = drain(err_r)
          status = supervise(process, deadline, arguments)
          settled = true
          Outcome.new(stdout: collect(stdout, out_r), stderr: collect(stderr, err_r), status: status)
        ensure
          process&.kill_and_reap unless settled
          feeder&.join(DRAIN_SECONDS)
          [in_r, in_w, out_r, err_r, out_w, err_w].compact.each do |io|
            io.close unless io.closed?
          rescue IOError
            nil
          end
        end

        private

          # Polls the leader under the deadline; a cancelled task kills the
          # group at once (the context's signal) and its `Cancelled` passes
          # through — a store never swallows a cancellation into a skip.
          def supervise(process, deadline, arguments)
            ExecutionContext.with_cancel_signal(-> { process.cancel }) do
              loop do
                ExecutionContext.current&.raise_if_cancelled!
                status = process.poll
                if status
                  # The leader exited; children still in the group (a
                  # repack) are ended with the guard, as bash's are.
                  process.kill_and_reap
                  return status
                end
                if @clock.call >= deadline
                  process.kill_and_reap
                  raise TimedOut, arguments
                end
                sleep(POLL_SECONDS)
              end
            end
          end

          def feed(io, stdin)
            if stdin.nil?
              io.close
              return nil
            end

            Thread.new do
              io.write(stdin)
            rescue IOError, SystemCallError
              nil
            ensure
              io.close unless io.closed?
            end
          end

          def drain(io)
            Thread.new do
              io.read.to_s.b
            rescue IOError, SystemCallError
              "".b
            end
          end

          # A reader still blocked after the group is dead is holding a
          # pipe somebody outside the group kept: the read end is closed
          # under it and what it had is what we get.
          def collect(thread, io)
            return thread.value if thread.join(DRAIN_SECONDS)

            io.close unless io.closed?
            thread.join(DRAIN_SECONDS)
            thread.alive? ? "".b : thread.value.to_s
          end

          def environment(index:, redirect:)
            base = ChildEnv.call.reject { |key, _| DROPPED.include?(key) }
            base = base.merge(IDENTITY).merge(NEUTRAL)
            return base unless redirect

            base.merge(
              "GIT_DIR" => @git_dir, "GIT_WORK_TREE" => @work_tree,
              "GIT_INDEX_FILE" => index || File.join(@git_dir, "index")
            )
          end
      end
    end
  end
end
