module Rho
  class Runner
    module Checkpoints
      # Repository reads and Git's ignore grammar. Checkpoint bytes, records and
      # retention never pass through Git. Calls use the ordinary owned-process
      # cancellation/deadline path and do not update the source checkout's index.
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

        DROPPED = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_NAMESPACE GIT_ALTERNATE_OBJECT_DIRECTORIES].freeze
        NEUTRAL = {
          "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0",
          "GIT_OPTIONAL_LOCKS" => "0",
        }.freeze
        POLL_SECONDS = 0.01
        # How long a reader is given to drain a dead group's pipe before the
        # read end is closed under it — a process outside the group holding
        # the write end is the one shape that could hold a reader forever.
        DRAIN_SECONDS = 1.0

        attr_reader :binary, :git_dir, :work_tree

        def initialize(binary:, work_tree:, git_dir: nil, clock: nil)
          @binary = binary
          @git_dir = git_dir
          @work_tree = work_tree
          @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        end

        # The call's stdout, or `Failed` on a non-zero exit — for every call
        # whose failure is the operation's failure.
        def read(*arguments, deadline:, stdin: nil)
          outcome = call(*arguments, deadline: deadline, stdin: stdin)
          raise Failed.new(arguments, outcome.status, outcome.stderr) unless outcome.ok?

          outcome.stdout
        end

        # Nonzero exit can be an ordinary answer (no ignore match, unborn HEAD).
        def call(*arguments, deadline:, stdin: nil)
          # A cancelled task spawns nothing: the check runs BEFORE the
          # spawn (and before every poll), so a cancellation is always its
          # own exception and never a killed git read as a skip.
          ExecutionContext.current&.raise_if_cancelled!
          raise TimedOut, arguments if @clock.call >= deadline

          in_r, in_w = IO.pipe
          out_r, out_w = IO.pipe
          err_r, err_w = IO.pipe
          process = nil
          settled = false
          process = OwnedProcess.spawn(
            environment, @binary, *arguments.map(&:to_s),
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
                  # End remaining children with the same guard as shell tools.
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

          def environment
            base = ChildEnv.call.reject { |key, _| DROPPED.include?(key) }.merge(NEUTRAL)
            @git_dir ? base.merge("GIT_DIR" => @git_dir, "GIT_WORK_TREE" => @work_tree) : base
          end
      end
    end
  end
end
