require "fileutils"
require "io/wait"
require "tmpdir"
require_relative "../fixture_project"
require_relative "declared_set"
require_relative "read_class"

module E2E
  module TaskBench
    # THE READS OF A TWO-STEP DRAW, ANSWERED FROM THE FIXTURE: the objective's bytes written fresh
    # into a directory the draw owns (`open`'s block; the copy is removed when it returns), and
    # each read-class call answered as a runner answers it — a `Rho::Runner::Result`, its text the
    # model's and its `is_error` the wire's — by rho-runner's own handlers over that copy (`read`,
    # `grep`, `find`, `ls`, the schema refusal before the handler as `TaskRun#admit` words it) and
    # rho's own process tools over an empty table (nothing was started). What is read-class is
    # judged under the same copy's `ToolEnv` (`read_class?`). An admitted `bash` passes rho's schema
    # and lands its workdir as rho does, then runs as argv — no shell ever sees the model's text —
    # each stage in the copy, the stages joined by pipes in one process group, stdout and stderr
    # merged, stdin empty, the environment reduced to PATH and the C locale, under a wall clock that
    # kills the group and an output cap that cuts it. Its answer is worded as rho's `bash` words one
    # — the silence, the exit, the clock, the missing workdir, rho's own line convention over the
    # output (`Truncation`) — and `task_bench_emulator_harness_test` runs rho's `bash` beside it on
    # the same commands to hold the two equal.
    #
    # THE RECORDED DIFFERENCES from rho's `bash`, each deliberate: the environment and locale are
    # the reduced pair above (no harness variable reaches a command); the clock is the emulator's
    # (a model's `timeout` is checked by the schema, never honoured); and past rho's bound
    # (`Truncation`'s 2000 lines / 50 KiB) rho keeps the output's TAIL and spills the whole to a
    # capture outside the fixture that no read-class call could open, where the emulator keeps no
    # capture — it reads up to its own cap and keeps the HEAD, saying so. A fixture of a few files
    # reaches neither bound. A call that is not read-class is never answered: reaching here is the
    # harness's fault.
    class Emulator
      TIMEOUT_SECONDS = 10
      OUTPUT_CAP_BYTES = 64 * 1024
      READ_CHUNK_BYTES = 16 * 1024
      PROJECT = "project".freeze
      # No provider key or other harness variable reaches a command: the child's whole environment.
      CHILD_ENV = { "PATH" => ENV.fetch("PATH"), "LC_ALL" => "C" }.freeze

      def self.open(fixture:, timeout_seconds: TIMEOUT_SECONDS)
        Dir.mktmpdir("task-bench") { |dir| yield new(fixture: fixture, dir: dir, timeout_seconds: timeout_seconds) }
      end

      attr_reader :root

      # `dir` is the draw's own; the fixture lands in `<dir>/project`, which exists even when the
      # fixture is empty (an objective with none reads an empty project).
      def initialize(fixture:, dir:, timeout_seconds: TIMEOUT_SECONDS)
        FileUtils.mkdir_p(File.join(dir, PROJECT))
        @root = FixtureProject.write(dir, PROJECT, fixture).root
        @timeout_seconds = timeout_seconds
        registry = DeclaredSet.registry # loads rho's lib, before any of its types is named
        @env = tool_env(dir)
        @toolset = registry.toolset(env: @env)
      end

      # Whether this copy answers every call of a message (`ReadClass`, under the copy's own env).
      def read_class?(calls) = ReadClass.all?(calls, declarations: ReadClass.declarations, env: @env)

      def answer(call)
        unless ReadClass.read?(call, declarations: ReadClass.declarations, env: @env)
          raise ArgumentError, "#{call.name} is not read-class; the emulator answers reads alone"
        end

        tool = @toolset.fetch(call.tool)
        refusal = Rho::Runner::InputSchema.refusal(tool.validator, call.arguments)
        if refusal
          Rho::Runner::Result.error("invalid_tool_arguments: #{refusal}")
        elsif call.tool == Rho::Runner::Tools::Bash::NAME
          shell_free(ReadClass.bash_argv(call.argument("command")), call.argument("workdir"))
        else
          handled(tool, call)
        end
      end

      private

        def tool_env(dir)
          processes = Rho::Processes::Registry.new(log_dir: File.join(dir, "processes"),
            state_file: File.join(dir, "processes.json"))
          Rho::Runner::ToolEnv.new(root: @root, artifacts_dir: File.join(dir, "artifacts"), processes: processes)
        end

        # One of rho's own handlers over the copy; one that raises — a model's U+0000 in a pattern
        # reaches its spawn — is answered as the runner answers it (`TaskRun`), a failure the model
        # reads, never a harness fault.
        def handled(tool, call)
          tool.handler.call(call.arguments, nil)
        rescue StandardError => error
          Rho::Runner::Result.error("The tool could not run: #{error.class}: #{error.message}")
        end

        # The workdir lands where rho's `bash` lands it: resolved against the root, absent or empty
        # being the root itself (`File.expand_path("", root)` is the root).
        def shell_free(argvs, workdir)
          directory = @env.resolve(workdir.to_s)
          if File.directory?(directory)
            piped(argvs, directory)
          else
            Rho::Runner::Result.error("Working directory does not exist: #{directory}\nCannot execute bash commands.")
          end
        end

        # A stage the model's own text keeps from starting — a U+0000 in an argument no path check
        # reads — is answered as rho's `bash` answers a shell that cannot start. A program the
        # machine lacks stays the harness's fault: the read-class list names only what it runs.
        def piped(argvs, directory)
          reader, writer = IO.pipe
          pids = begin
            spawned(argvs, directory, writer)
          rescue ArgumentError => error
            return Rho::Runner::Result.error("Failed to start bash: #{error.message}")
          ensure
            writer.close
          end
          output, stop = drained(reader)
          stop_group(pids.first) unless stop == :eof
          rendered(output, stop, pids.map { |pid| Process.wait2(pid).last }.last)
        ensure
          reader&.close
        end

        # Every stage in the first stage's group; the links between stages are the parent's to
        # close once every child holds its ends. `[name, name]` keeps even a one-word argv off the
        # shell. A stage that fails to start stops and releases the stages already started.
        def spawned(argvs, directory, out)
          links = Array.new(argvs.length - 1) { IO.pipe }
          inputs = [File::NULL, *links.map(&:first)]
          outputs = [*links.map(&:last), out]
          argvs.each_with_index.reduce([]) do |pids, (argv, i)|
            pids + [Process.spawn(CHILD_ENV, [argv.first, argv.first], *argv.drop(1), chdir: directory,
              in: inputs[i], out: outputs[i], err: out, pgroup: pids.first || true, unsetenv_others: true)]
          rescue StandardError
            stop_group(pids.first) unless pids.empty?
            pids.each { |pid| Process.detach(pid) }
            raise
          end
        ensure
          links&.flatten&.each(&:close)
        end

        # The merged output until every stage closed it (`:eof`), the cap (`:cap`) or the clock
        # (`:timeout`).
        def drained(reader)
          deadline = monotonic + @timeout_seconds
          output = "".b
          loop do
            remaining = deadline - monotonic
            return [output, :timeout] if remaining <= 0 || reader.wait_readable(remaining).nil?

            chunk = reader.read_nonblock(READ_CHUNK_BYTES, exception: false)
            return [output, :eof] if chunk.nil?

            output = output + chunk unless chunk == :wait_readable
            return [output.byteslice(0, OUTPUT_CAP_BYTES), :cap] if output.bytesize >= OUTPUT_CAP_BYTES
          end
        end

        # A group whose members have all exited answers EPERM on macOS and ESRCH elsewhere.
        def stop_group(pgid)
          Process.kill(:KILL, -pgid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end

        # The runner's own shapes: "(no output)" for silence, a failing exit as the command's error
        # with its code beside the output, the clock as an error; the cap is a note under the output
        # (the recorded difference: the head, no capture).
        def rendered(output, stop, status)
          text = String.new(output, encoding: Encoding::UTF_8).scrub
          case stop
          when :timeout then Rho::Runner::Result.error(beside(shown(text), "Command timed out after #{seconds} seconds"))
          when :cap then Rho::Runner::Result.ok("#{text}\n\n[output cut at #{OUTPUT_CAP_BYTES / 1024} KiB]")
          when :eof then exited(shown(text), status.exitstatus)
          else raise ArgumentError, "no drain ends #{stop.inspect}"
          end
        end

        # The output as rho's `bash` shows it: rho's own window (`Truncation.truncate_tail`, whose
        # line convention drops one trailing newline), its bound lifted — the emulator's cap bounds
        # what was read.
        def shown(text)
          Rho::Runner::Truncation.truncate_tail(text, max_lines: Float::INFINITY, max_bytes: Float::INFINITY).content
        end

        # Silence is said only once the command exited; the clock says nothing in its place.
        def exited(text, code)
          said = text.empty? ? "(no output)" : text
          if code.nil? || code.zero?
            Rho::Runner::Result.ok(said)
          else
            Rho::Runner::Result.error(beside(said, "Command exited with code #{code}"))
          end
        end

        def beside(text, status_line) = text.empty? ? status_line : "#{text}\n\n#{status_line}"

        def seconds = @timeout_seconds == @timeout_seconds.to_i ? @timeout_seconds.to_i.to_s : @timeout_seconds.to_s

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
