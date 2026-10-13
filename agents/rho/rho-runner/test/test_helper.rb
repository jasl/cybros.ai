$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rho/runner"
require "tmpdir"
require "minitest/autorun"

module RunnerTest
  # THE TOOLS' EXECUTION ENVIRONMENT, over a throwaway root, its captures
  # placed as a host places them: under a work dir beside the root,
  # never inside it. A context is bound for the block because every tool
  # checks cancellation at its own checkpoints and reads it off the thread
  # — the same way the pool binds it on a worker.
  module Helpers
    def with_tool_env(subdir: nil, bash_timeout_seconds: 30)
      Dir.mktmpdir("rho-runner-test") do |tmp|
        real = File.join(File.realpath(tmp), "root")
        Dir.mkdir(real)
        Dir.mkdir(File.join(real, subdir)) if subdir
        env = Rho::Runner::ToolEnv.new(
          root: real,
          artifacts_dir: Rho::Runner::ToolEnv.artifacts_dir_for(root: real, work_dir: File.join(tmp, "work")),
          subdir: subdir, bash_timeout_seconds: bash_timeout_seconds
        )
        Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
          yield(env, env.root)
        end
      end
    end

    # The predecessor ran a tool inside an Async task when a test needed it
    # running WHILE the test read pids from a pipe. Ours runs on a native
    # worker, so the concurrency a test needs is a thread — and `stop` is
    # the interruption a handler can actually receive: its context
    # cancelled, exactly as the pool does when the runner drains.
    class BackgroundTask
      def initialize(context, &body)
        @context = context
        @thread = Thread.new { Rho::Runner::ExecutionContext.with(context) { body.call } }
        # `Cancelled` out of a checkpoint is one of the two lawful ends
        # (`settle`, below) and is read from the thread by `wait`/`settle`;
        # Ruby's default would also print it as an unhandled thread death
        # whenever the checkpoint wins the race — a stack trace on a green
        # run, seen under load (L-59), and read as a red suite in waiting.
        @thread.report_on_exception = false
      end

      def wait = @thread.value
      def finished? = !@thread.alive?

      # `Thread#join` RE-RAISES what killed the thread, so a cancelled
      # handler whose checkpoint won the race raised `Cancelled` out of the
      # stop itself, before any `settle` could read it. The stop only
      # requests and waits; the outcome is `wait`/`settle`'s to report.
      def stop
        @context.cancel
        @thread.join(5)
      rescue Rho::Runner::ExecutionContext::Cancelled
        @thread
      end

      # A CANCELLED HANDLER ENDS ONE OF TWO WAYS, and both are the point of
      # a cancellation test: the KILLed leader was reaped before the next
      # checkpoint (a Result comes back), or the checkpoint won (Cancelled
      # comes out). Which one is a race with the kernel's reaper that the
      # test must not care about — `wait` alone re-raised the second and
      # failed the suite one run in three.
      def settle
        wait
      rescue Rho::Runner::ExecutionContext::Cancelled => error
        error
      end
    end

    def run_async(&) = BackgroundTask.new(Rho::Runner::ExecutionContext.current, &)

    def with_tmpdir(&) = Dir.mktmpdir("rho-runner-test", &)

    # A dead process stays a zombie until its (re-)parent reaps it, and an
    # orphan re-parented to init is reaped on the reaper's schedule — so
    # `kill(0, pid)` can still succeed for a beat after the process
    # observably died. Poll to a deadline rather than asserting one race.
    # Works for a process GROUP too: pass the negative pgid.
    def assert_process_gone(pid, timeout: 2)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        Process.kill(0, pid)
        flunk "process #{pid} still exists after #{timeout}s" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.02
      rescue Errno::ESRCH
        break
      end
    end

    def with_lock(queue, path, &) = queue.with_lock(path, &)

    def with_cancelled_tool_env
      with_tool_env do |env, root|
        Rho::Runner::ExecutionContext.current.cancel
        yield(env, root)
      end
    end

    # THE PORT ON THE CONTEXT: the same throwaway root,
    # the context placed with a binding anchored at `anchor` and a ports
    # resolver that answers `port` for that anchor alone — the per-call
    # lookup the tools make through `ExecutionContext#port`. `directories`
    # widen the root set the port routes on.
    def with_ported_env(port, anchor: "conv-1", directories: [], resolver: nil)
      Dir.mktmpdir("rho-runner-test") do |tmp|
        real = File.join(File.realpath(tmp), "root")
        Dir.mkdir(real)
        env = Rho::Runner::ToolEnv.new(
          root: real, directories: directories,
          artifacts_dir: Rho::Runner::ToolEnv.artifacts_dir_for(root: real, work_dir: File.join(tmp, "work"))
        )
        binding = Rho::Runner::Environment::Binding.new(root: real, directories: directories, anchor: anchor)
        ports = resolver || ->(key) { key == anchor ? port : nil }
        context = Rho::Runner::ExecutionContext.new(tool_env: env, binding: binding, ports: ports)
        Rho::Runner::ExecutionContext.with(context) { yield(env, real) }
      end
    end
  end

  # A SCRIPTED PORT: the duck rho-runner's tools speak to (`Rho::Runner::
  # FsPort`), backed by an in-memory table of buffers keyed by path — the
  # editor's unsaved view, distinct from the disk — recording every ask
  # and every drop. `fail:` scripts one error per method (`read:` /
  # `write:`), raised on that call instead of answering.
  class PortDouble
    include Rho::Runner::FsPort

    attr_reader :calls, :dropped, :buffers, :client

    def initialize(read: true, write: true, buffers: {}, client: "zed", fail: {})
      @read = read
      @write = write
      @buffers = buffers.dup.freeze
      @client = client
      @fail = fail
      @calls = []
      @dropped = []
    end

    def serves?(method) = { read: @read, write: @write }.fetch(method)

    def read_text(path, line:, limit:)
      @calls << [:read, path, { line: line, limit: limit }]
      raise @fail[:read] if @fail[:read]

      text = @buffers.fetch(path) { raise Rho::Runner::FsPort::NotFound, "no buffer for #{path}" }
      return text if line.nil? && limit.nil?

      lines = text.lines
      raise Rho::Runner::FsPort::BeyondEof, "line #{line} is past the last line" if line > lines.length && line > 1

      lines.drop(line - 1).take(limit || lines.length).join
    end

    def write_text(path, text)
      @calls << [:write, path, text]
      raise @fail[:write] if @fail[:write]

      @buffers = @buffers.merge(path => text).freeze
      nil
    end

    def drop(detail)
      @dropped << detail
      nil
    end

    def asked?(method) = @calls.any? { |kind, *| kind == method }
  end
end
